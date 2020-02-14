﻿using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace WCGL
{
    [ExecuteInEditMode]
    public class DeferredInkingCamera : MonoBehaviour
    {
        static Material DrawMaterial, GBufferMaterial;

        Camera cam;
        CommandBuffer commandBuffer;
        RenderTexture gBuffer;

        public bool generateGBuffer = true;

        enum RenderPhase { GBuffer, Line }

        void Start() { } //for Inspector ON_OFF

        void resizeRenderTexture()
        {
            var gbSize = new Vector2Int(cam.pixelWidth, cam.pixelHeight);

            if (gBuffer == null || gBuffer.width != gbSize.x || gBuffer.height != gbSize.y)
            {
                if (gBuffer != null) gBuffer.Release();
                gBuffer = new RenderTexture(gbSize.x, gbSize.y, 0, RenderTextureFormat.ARGB32);
                gBuffer.name = "DeferredInking_G-Buffer";
                gBuffer.wrapMode = TextureWrapMode.Clamp;
                gBuffer.filterMode = FilterMode.Point;
            }
        }

        void Awake()
        {
            cam = GetComponent<Camera>();
            if (cam == null)
            {
                Debug.LogError(name + " does not have camera.");
                return;
            }

            commandBuffer = new CommandBuffer();
            commandBuffer.name = "DeferredInking";
            cam.AddCommandBuffer(CameraEvent.AfterSkybox, commandBuffer);

            resizeRenderTexture();

            if (DrawMaterial == null)
            {
                var shader = Shader.Find("Hidden/DeferredInking/Draw");
                DrawMaterial = new Material(shader);

                shader = Shader.Find("Hidden/DeferredInking/GBuffer");
                GBufferMaterial = new Material(shader);
            }
        }

        private void OnPreRender()
        {
            resizeRenderTexture();

            var depthBuffer = (RenderTargetIdentifier)BuiltinRenderTextureType.Depth;

            if (generateGBuffer == true)
            {
                commandBuffer.SetRenderTarget(gBuffer.colorBuffer, depthBuffer);
                commandBuffer.ClearRenderTarget(false, true, Color.clear);
                render(RenderPhase.GBuffer);
            }

            commandBuffer.SetRenderTarget(BuiltinRenderTextureType.CameraTarget);
            commandBuffer.SetGlobalTexture("_GBuffer", gBuffer.colorBuffer);
            commandBuffer.SetGlobalTexture("_GBufferDepth", depthBuffer);
            if (cam.orthographic) { commandBuffer.EnableShaderKeyword("_ORTHO_ON"); }
            else { commandBuffer.DisableShaderKeyword("_ORTHO_ON"); }
            render(RenderPhase.Line);
        }

        private void render(RenderPhase phase)
        {
            Material mat = GBufferMaterial;

            foreach (var model in DeferredInkingModel.Instances)
            {
                if (model.isActiveAndEnabled == false) continue;
                var id = new Vector2(model.modelID, 0);

                foreach (var mesh in model.meshes)
                {
                    var renderer = mesh.mesh;
                    if (renderer == null || renderer.enabled == false) continue;

                    if (phase == RenderPhase.Line)
                    {
                        mat = mesh.material;
                        if (mat == null) continue;

                        if (mesh.curvatureBuffer == null) Debug.Log("NULL: " + mesh.mesh.name);
                        else mesh.curvatureBuffer.generateCommendBuffer(commandBuffer);
                    }

                    if (phase == RenderPhase.GBuffer || mat.GetTag("LineType", false) == "DeferredInking")
                    {
                        id.y = mesh.meshID;
                        commandBuffer.SetGlobalVector("_ID", id);
                    }
                    commandBuffer.DrawRenderer(renderer, mat);
                }
            }
        }

        private void OnPostRender()
        {
            commandBuffer.Clear();
        }
    }
}