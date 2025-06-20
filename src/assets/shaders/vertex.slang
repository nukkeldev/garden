[[vk::binding(0, 1)]]
uniform ConstantBuffer<float4x4> mvp;

struct VertexInput
{
    float3 position : POSITION;
    float3 color : COLOR;
};

struct VertexOutput
{
    float3 color;
};

struct VertexStageOutput
{
    float4 sv_position : SV_Position;
    VertexOutput vertex : VertexOutput;
};

[shader("vertex")]
VertexStageOutput vertexMain(VertexInput input)
{
    VertexStageOutput output;

    output.vertex.color = input.color;
    output.sv_position = mul(mvp, float4(input.position, 1.0));

    return output;
}
