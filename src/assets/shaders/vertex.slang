[[vk::binding(0, 1)]]
uniform ConstantBuffer<PerFrameData> pfd;
[[vk::binding(1, 1)]]
uniform ConstantBuffer<float4x4> normalMat;

struct PerFrameData
{
    float4x4 model;
    float4x4 view;
    float4x4 proj;
}

struct VertexInput
{
    float3 position : POSITION;
    float3 normal : NORMAL;
    float3 color : COLOR;
};

struct VertexOutput
{
    float3 fragmentPosition;
    float3 normalDirection;
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

    output.vertex.fragmentPosition = mul(pfd.model, float4(input.position, 1.0)).xyz;
    output.vertex.normalDirection = normalize(mul((float3x3)normalMat, input.normal));
    output.vertex.color = input.color;
    output.sv_position = mul(pfd.proj, mul(pfd.view, float4(output.vertex.fragmentPosition, 1.0)));

    return output;
}
