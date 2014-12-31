#ifndef MAYA_HELPERS_H
#define MAYA_HELPERS_H

#if !defined(NO_CUDA)
#error This header requires NO_CUDA.
#endif

#include <maya/MArrayDataHandle.h>
#include <maya/MDataHandle.h>
#include <maya/MObject.h>
#include <maya/MPlug.h>
#include <maya/MString.h>
#include <maya/MMatrix.h>
#include <maya/MDagPath.h>
#include <string>
#include <vector>

#include "transfo.hpp"

namespace DagHelpers
{
    Transfo MMatrixToTransfo(const MMatrix &mmat);

    MStatus getConnectedPlugWithName(MPlug inputPlug, std::string name, MPlug &result);
    MMatrix getMatrixFromPlug(MPlug plug, MStatus *status);
    MStatus findAncestorDeformer(MPlug inputPlug, MFn::Type type, MPlug &resultPlug);
    MStatus getMDagPathsFromSkinCluster(MPlug skinClusterPlug, std::vector<MDagPath> &out);
    int findClosestAncestor(const std::vector<MDagPath> &dagPaths, MDagPath dagPath);
    MStatus getInputGeometryForSkinClusterPlug(MPlug skinClusterPlug, MObject &plug);
    MStatus setMatrixPlug(MPlug plug, MObject attr, MMatrix matrix);


    template<class T>
    T readHandle(MDataHandle handle, MStatus *status);

    template<> inline MDataHandle readHandle(MDataHandle handle, MStatus *status) { return handle; }
    template<> inline MMatrix readHandle(MDataHandle handle, MStatus *status) { return handle.asMatrix(); }
    template<> inline bool readHandle(MDataHandle handle, MStatus *status) { return handle.asBool(); }

    template<class T>
    inline T readHandle(MDataBlock &dataBlock, const MObject &attribute, MStatus *status)
    {
        MDataHandle itemHandle = dataBlock.inputValue(attribute, status);
        if(*status != MS::kSuccess) return T();
        return readHandle<T>(itemHandle, status);
    }

    template<class T>
    inline T readArrayHandle(MArrayDataHandle arrayHandle, MStatus *status)
    {
        MDataHandle itemHandle = arrayHandle.inputValue(status);
        if(*status != MS::kSuccess) return T();
        return readHandle<T>(itemHandle, status);
    }

    template<class T>
    inline T readArrayHandleLogicalIndex(MArrayDataHandle arrayHandle, int logicalIndex, MStatus *status)
    {
        *status = arrayHandle.jumpToElement(logicalIndex);
        if(*status != MS::kSuccess) return T();

        return readArrayHandle<T>(arrayHandle, status);
    }

    bool getPlugConnectedTo(const MObject& node, const MString &attribute, MPlug& connectedPlug);
    MObject getNodeConnectedTo(const MObject& node, const MString &attribute);
    MObject getSourceNodeConnectedTo ( const MObject& node, const MString& attribute );
    MObject getSourceNodeConnectedTo ( const MPlug& inPlug );
    bool getPlugConnectedTo ( const MObject& node, const MString &attribute, MPlug& connectedPlug );
    bool getPlugConnectedTo ( const MPlug& inPlug, MPlug& plug );
    MObject getNodeConnectedTo ( const MPlug& plug );


    MStatus setPlugValue(MPlug& plug, float x, float y);
    MStatus setPlugValue(MPlug& plug, float x, float y, float z);
    MStatus getPlugValue(const MPlug& plug, float& x, float& y, float& z);
}

#endif
