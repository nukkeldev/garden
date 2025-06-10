#version 450
layout(row_major) uniform;
layout(row_major) buffer;

#line 21 0
layout(location = 0)
out vec4 entryPointParam_fragmentMain_color_0;


#line 15
layout(location = 0)
in vec3 coarseVertex_color_0;




struct Fragment_0
{
    vec4 color_0;
};


#line 52
void main()
{



    Fragment_0 output_0;
    output_0.color_0 = vec4(coarseVertex_color_0, 1.0);

#line 58
    entryPointParam_fragmentMain_color_0 = output_0.color_0;

#line 58
    return;
}

