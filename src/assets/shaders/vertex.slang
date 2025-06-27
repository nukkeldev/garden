import "structs";

// Bindings

[[vk::binding(0, 1)]]
uniform ConstantBuffer<PerMeshVertexData> pmd;
[[vk::binding(1, 1)]]
uniform ConstantBuffer<PerFrameVertexData> pfd;

// Main

[shader("vertex")]
VertexStageOutput vertexMain(VertexInput input)
{
    VertexStageOutput output;

    output.vertex.fragmentPosition = mul(pmd.model, float4(input.position, 1.0)).xyz;
    output.vertex.normalDirection = normalize(mul((float3x3)pmd.normalMat, input.normal));
    output.sv_position = mul(pfd.view_proj, float4(output.vertex.fragmentPosition, 1.0));

    return output;
}
