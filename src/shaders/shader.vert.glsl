#version 450
layout(row_major) uniform;
layout(row_major) buffer;

#line 8 0
layout(location = 0)
out vec3 entryPointParam_vertexMain_coarseVertex_color_0;


#line 28
layout(location = 0)
in vec3 assembledVertex_position_0;


#line 28
layout(location = 1)
in vec3 assembledVertex_color_0;


#line 15
struct CoarseVertex_0
{
    vec3 color_0;
};


#line 28
struct VertexStageOutput_0
{
    CoarseVertex_0 coarseVertex_0;
    vec4 sv_position_0;
};


void main()
{

    VertexStageOutput_0 output_0;

#line 43
    output_0.coarseVertex_0.color_0 = assembledVertex_color_0;
    output_0.sv_position_0 = vec4(assembledVertex_position_0, 1.0);

    VertexStageOutput_0 _S1 = output_0;

#line 46
    entryPointParam_vertexMain_coarseVertex_color_0 = output_0.coarseVertex_0.color_0;

#line 46
    gl_Position = _S1.sv_position_0;

#line 46
    return;
}

