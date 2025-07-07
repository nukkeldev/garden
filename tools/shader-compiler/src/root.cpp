#include "slang.h"
#include "slang-com-helper.h"
#include "slang-com-ptr.h"
#include <iostream>
#include <fstream>
#include <vector>
// #include <stdio.h>

void diagnoseIfNeeded(slang::IBlob *diagnosticsBlob)
{
    if (diagnosticsBlob != nullptr)
    {
        std::cout << (const char *)diagnosticsBlob->getBufferPointer() << std::endl;
    }
}

extern "C"
{
    int __compileShader(const char *name, const char *path, const char *input,
                        char **outSpirvCode, size_t *outSpirvCodeLen,
                        char **outReflection, size_t *outReflectionLen)
    {
        // printf("Starting shader compilation for %s (%s)\n", name, path);

        // TODO: Make the sessions global so as to not recreate them throughout the program lifetime.
        // Create a global session.
        Slang::ComPtr<slang::IGlobalSession> globalSession;
        createGlobalSession(globalSession.writeRef());

        // printf("Created a global session.\n");

        // Describe a session for a target compiling for SPIRV 1.3.
        slang::SessionDesc sessionDesc = {};
        slang::TargetDesc targetDesc = {};
        targetDesc.format = SLANG_SPIRV;
        targetDesc.profile = globalSession->findProfile("spirv_1_3");

        sessionDesc.targets = &targetDesc;
        sessionDesc.targetCount = 1;

        // Create the session.
        Slang::ComPtr<slang::ISession> session;
        globalSession->createSession(sessionDesc, session.writeRef());

        // printf("Created a session for 'spirv_1_3' compilation.\n");

        // Load our program.
        Slang::ComPtr<slang::IModule> slangModule;
        {
            Slang::ComPtr<slang::IBlob> diagnosticsBlob;
            slangModule = session->loadModuleFromSourceString(name, path, input, diagnosticsBlob.writeRef());
            diagnoseIfNeeded(diagnosticsBlob);
            if (!slangModule)
            {
                return -1;
            }
        }

        // printf("Loaded module from source.\n");

        int32_t entrypoint_count = slangModule->getDefinedEntryPointCount();

        std::vector<slang::IComponentType *> components(1 + entrypoint_count);
        components[0] = slangModule;
        for (int i = 0; i < entrypoint_count; ++i)
        {
            Slang::ComPtr<slang::IEntryPoint> entrypoint;
            slangModule->getDefinedEntryPoint(i, entrypoint.writeRef());
            components[i + 1] = entrypoint;
        }

        Slang::ComPtr<slang::IComponentType> program;
        session->createCompositeComponentType(components.data(), components.size(), program.writeRef());

        // Link the module to it's dependencies for all annotated entrypoints.
        Slang::ComPtr<slang::IComponentType> linkedProgram;
        {
            Slang::ComPtr<slang::IBlob> diagnosticsBlob;
            SlangResult result = program->link(
                linkedProgram.writeRef(),
                diagnosticsBlob.writeRef());
            diagnoseIfNeeded(diagnosticsBlob);
            SLANG_RETURN_ON_FAIL(result);
        }

        // printf("Linked module.\n");

        // Compile the linked program into our SPIRV code.
        Slang::ComPtr<slang::IBlob> spirvCode;
        {
            Slang::ComPtr<slang::IBlob> diagnosticsBlob;
            SlangResult result = linkedProgram->getTargetCode(
                0,
                spirvCode.writeRef(),
                diagnosticsBlob.writeRef());
            diagnoseIfNeeded(diagnosticsBlob);
            SLANG_RETURN_ON_FAIL(result);
        }

        // printf("Compiled all entrypoints.\n");

        // Emit the reflection JSON.
        slang::ProgramLayout *layout = linkedProgram->getLayout();
        Slang::ComPtr<slang::IBlob> reflectionJson;
        {
            Slang::ComPtr<slang::IBlob> diagnosticsBlob;
            SlangResult result = layout->toJson(reflectionJson.writeRef());
            diagnoseIfNeeded(diagnosticsBlob);
            SLANG_RETURN_ON_FAIL(result);
        }

        // printf("Emitted reflection JSON.\n");

        *outSpirvCodeLen = spirvCode->getBufferSize();
        *outSpirvCode = (char *)malloc(*outSpirvCodeLen);
        if (*outSpirvCode)
            memcpy(*outSpirvCode, spirvCode->getBufferPointer(), *outSpirvCodeLen);

        *outReflectionLen = reflectionJson->getBufferSize();
        *outReflection = (char *)malloc(*outReflectionLen);
        if (*outReflection)
            memcpy(*outReflection, reflectionJson->getBufferPointer(), *outReflectionLen);

        // {
        //     std::fstream outFile("phong2.spv", std::ios::binary | std::ios::out);
        //     outFile.write(*outSpirvCode, *outSpirvCodeLen);
        //     outFile.close();
        // }

        // {
        //     std::fstream outFile("phong2.json", std::ios::binary | std::ios::out);
        //     outFile.write(*outReflection, *outReflectionLen);
        //     outFile.close();
        // }

        // printf("Compilation successful.\n");

        return 0;
    }
}

// int main()
// {
//     const char *shortestShader =
//         "RWStructuredBuffer<float> result;"
//         "[shader(\"compute\")]"
//         "[numthreads(1,1,1)]"
//         "void computeMain(uint3 threadId : SV_DispatchThreadID)"
//         "{"
//         "    result[threadId.x] = threadId.x;"
//         "}";

//     __compileShader("shortest", "shortest.slang", "");
// }