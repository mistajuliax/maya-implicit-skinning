#include "animesh_hrbf_heuristic.hpp"
#include "animesh.hpp"
#include "timer.hpp"
#include "utils_sampling.hpp"
#include "skeleton.hpp"
#include "hrbf_env.hpp"

#include <iostream>
#include <limits>
#include <cuda.h>

using namespace Cuda_utils;
using namespace HRBF_env;

HRBF_sampling::HRBF_sampling(const Mesh *mesh_, const Skeleton *skel_, const VertToBoneInfo &vertToBoneInfo_):
    _bone_id(-1),
    _factor_siblings(false),
    vertToBoneInfo(vertToBoneInfo_),
    mesh(mesh_),
    skel(skel_)
{ }

void HRBF_sampling::factor_samples(std::vector<int>& vert_ids,
                               std::vector<Vec3_cu>& vertices,
                               std::vector<Vec3_cu>& normals) const
{
    vert_ids.clear();
    vertices.clear();
    normals. clear();

    int parent = skel->parent( _bone_id );
    std::vector<int> dummy(1, _bone_id);
    const std::vector<int>& sons = parent == -1 ? dummy : skel->get_sons(parent);
    assert(sons.size() > 0);

    if(_factor_siblings && sons[0] == _bone_id)
        return;

    for( unsigned i = 0; i < sons.size(); i++)
    {
        const int bone_id = _factor_siblings ? sons[i] : _bone_id;
        const auto &ids   = vertToBoneInfo.h_verts_id_per_bone.at(bone_id);

        vert_ids.insert(vert_ids.end(), ids.begin(), ids.end());

        vertices.reserve(vertices.size() + ids.size());
        normals.reserve(normals.size() + ids.size());
        for(int vert_id: ids) {
            Vec3_cu vertex = mesh->get_vertex(vert_id);
            Vec3_cu normal = mesh->get_normal(vert_id).normalized();
            vertices.push_back(vertex);
            normals.push_back(normal);
        }

        if( !_factor_siblings ) break;
    }
}

// -----------------------------------------------------------------------------

void HRBF_sampling::clamp_samples(std::vector<int>& vert_ids_,
                              std::vector<Vec3_cu>& verts_,
                              std::vector<Vec3_cu>& normals_) const
{
    std::vector<int> vert_ids;
    std::vector<Vec3_cu> verts;
    std::vector<Vec3_cu> normals;

    vert_ids.reserve( vert_ids_.size() );
    verts.   reserve( verts_.size()    );
    normals. reserve( normals_.size()  );

    const Bone* b = skel->get_bone(_bone_id).get();
    const float length = b->length();
    float jlength = length * _jmax;
    float plength = length * _pmax;

    for(unsigned id = 0; id < verts_.size(); id++)
    {
        const Point_cu vert = verts_[id].to_point();
        const float dist_proj = b->dist_proj_to(vert);

        Vec3_cu dir_proj = vert - (b->org() + b->dir().normalized() * dist_proj);

        const Vec3_cu normal = normals_[id];

        const std::vector<int>& sons = skel->get_sons(_bone_id);
        bool leaf = sons.size() > 0 ? skel->is_leaf(sons[0]) : true;

        if( (dist_proj >= -plength ) &&
            (dist_proj < (length + jlength) || leaf) &&
            dir_proj.dot(normal) >= _fold )
        {
            verts.   push_back( verts_   [id] );
            vert_ids.push_back( vert_ids_[id] );
            normals. push_back( normal        );
        }
    }

    vert_ids_.swap( vert_ids );
    verts_.   swap( verts    );
    normals_. swap( normals  );
}

// -----------------------------------------------------------------------------

void Adhoc_sampling::sample(std::vector<Vec3_cu>& out_verts,
                        std::vector<Vec3_cu>& out_normals) const
{
    std::vector<Vec3_cu> in_verts;
    std::vector<int>     in_vert_ids;
    std::vector<Vec3_cu> in_normals;
    factor_samples(in_vert_ids, in_verts, in_normals);

    std::vector<bool> done;
    done.resize(in_verts.size(), false);

    const Bone* b = skel->get_bone(_bone_id).get();
    float length = b->length();
    float jlength = length * _jmax;
    float plength = length * _pmax;

    for(unsigned id = 0; id < in_verts.size(); id++)
    {
        Point_cu vert = in_verts[id].to_point();
        float dist_proj = b->dist_proj_to(vert);

        Vec3_cu dir_proj = vert - (b->org() + b->dir().normalized() * dist_proj);

        Vec3_cu normal = in_normals[id];
        if(dist_proj >= -jlength && dist_proj < (length + plength) &&
                dir_proj.dot(normal) >= _fold )
        {
            // Check for to close samples
            float dist = std::numeric_limits<float>::infinity();
            for(unsigned j = 0; j < in_verts.size(); j++)
            {
                float norm = (vert.to_vector() - in_verts[j]).norm();
                if( (unsigned)id != j && !done[j] && norm < dist)
                    dist = norm;
            }

            if(dist > _mind)
            {
                out_verts.  push_back( in_verts[id] );
                out_normals.push_back( normal       );
            }
        }
        done[id] = true;
    }
}

// -----------------------------------------------------------------------------

void Poisson_disk_sampling::sample(std::vector<Vec3_cu>& out_verts,
                          std::vector<Vec3_cu>& out_normals) const
{
    // The goal here is to build from the cluster of vertices bound to a single
    // bone of id '_bone_id' its associated sub mesh, and then sample the
    // surface of this sub mesh with the poisson disk strategy
    std::vector<Vec3_cu> in_verts;
    std::vector<int>     in_vert_ids;
    std::vector<Vec3_cu> in_normals;
    factor_samples(in_vert_ids, in_verts, in_normals);

    // XXX: This culls too many vertices, and I'm not sure how this is supposed to
    // work.  Disable it for now, since the results are reasonable without it.
//    clamp_samples (in_vert_ids, in_verts, in_normals);

    if( in_verts.size() == 0) return;

    assert( in_vert_ids.size() == in_verts.size());
    const int size_sub_mesh = in_vert_ids.size();

    std::map<int, int> meshToCluster; // map[mesh_idx] = idx_in_verts_ids
    for(int i = 0; i < size_sub_mesh; i++)
        meshToCluster[ in_vert_ids[i] ] = i;

    // The piece of mesh defined by the bone cluster
    std::vector<int> sub_tris;
    sub_tris.reserve( size_sub_mesh * 3 * 3);

    // Building 'sub_verts' and sub_tris arrays
    std::vector<bool> done(size_sub_mesh, false);
    // Look up vertex cluster
    for(int i = 0; i < size_sub_mesh; i++)
    {
        const int idx = in_vert_ids[i];
        // Look up neighboors
        int nb_neigh = mesh->get_edge_offset(idx*2 + 1);
        int dep      = mesh->get_edge_offset(idx*2    );
        int end      = dep + nb_neigh;
        for(int n = dep; n < end; n++)
        {
            int neigh0 = mesh->get_edge( n );
            int neigh1 = mesh->get_edge((n+1) >= end ? dep : n+1);

            std::map<int, int>::iterator it0 = meshToCluster.find( neigh0 );
            std::map<int, int>::iterator it1 = meshToCluster.find( neigh1 );

            // Must be in the map (otherwise doesn't belong to the cluster)
            if(it0 != meshToCluster.end() && it1 != meshToCluster.end() )
            {
                // Must not be already treated
                if( !done[it0->second] && !done[it1->second] )
                {
                    // Add the triangles
                    sub_tris.push_back( it0->second );
                    sub_tris.push_back( it1->second );
                    sub_tris.push_back( i           );
                }
            }
        }
        // Tag vertex as treated
        done[i] = true;
    }

    // Compute the poisson disk distribution on the sub mesh
    if(sub_tris.size() > 0)
        Utils_sampling::poisson_disk(_mind, _nb_samples, in_verts, in_normals, sub_tris, out_verts, out_normals);
    std::cout << "Poisson disk sampling done. " << out_verts.size();
    std::cout << "samples created" << std::endl;
}
