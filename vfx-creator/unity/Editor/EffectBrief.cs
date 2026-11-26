using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using UnityEngine;

namespace VfxCreator.Editor
{
    [Serializable]
    internal sealed class EffectAttachment
    {
        public string anchor;
        public string orientation;
    }

    [Serializable]
    internal sealed class EffectBrief
    {
        public string mode;
        public EffectAttachment attachment;
    }

    [Serializable]
    internal sealed class EffectPlayback
    {
        public int version = 1;
        public string id;
        public string prefab;
        public string mode;
        public EffectAttachment attachment;
        public string[] startEmitters;

        internal static EffectPlayback Prepare(GameObject root, Recipe recipe, ParticleSystem[] layers, Request request)
        {
            var systems = layers.Where(system => system != null).ToArray();
            var trails = root.GetComponentsInChildren<TrailRenderer>();
            var linkedEmitters = new HashSet<ParticleSystem>();
            foreach (var system in systems)
            {
                var subEmitters = system.subEmitters;
                for (int i = 0; i < subEmitters.subEmittersCount; i++)
                    linkedEmitters.Add(subEmitters.GetSubEmitterSystem(i));
            }
            // Unity can share Play On Awake across a particle hierarchy. The recipe owns per-layer startup.
            var startEmitters = layers.Where((system, index) =>
                system != null && recipe.layers[index].playOnAwake && !linkedEmitters.Contains(system)).ToArray();
            string mode = request.effectBrief.mode;
            if (mode == "trail")
            {
                if (trails.Length == 0)
                    throw new ArgumentException("A trail effect needs at least one TrailRenderer layer.");
            }
            else
            {
                if (trails.Length != 0 || startEmitters.Length == 0)
                    throw new ArgumentException($"A {mode} effect needs a particle emitter and cannot use TrailRenderer layers.");
                if (mode == "oneShot" && systems.Any(system => system.main.loop))
                    throw new ArgumentException("A oneShot effect cannot have looping particle systems.");
                if (mode == "loop" && !startEmitters.Any(system => system.main.loop))
                    throw new ArgumentException("A loop effect needs a looping start emitter.");
            }

            foreach (var system in systems)
            {
                var main = system.main;
                main.playOnAwake = false;
            }
            foreach (var trail in trails) trail.emitting = false;

            return new EffectPlayback
            {
                id = request.id,
                mode = mode,
                attachment = request.effectBrief.attachment,
                startEmitters = startEmitters.Select(system => AddressOf(root.transform, system.transform)).ToArray()
            };
        }

        internal ParticleSystem[] ResolveEmitters(Transform root)
        {
            return startEmitters.Select(address =>
            {
                var node = root;
                foreach (string index in address.Split('/'))
                    node = node.GetChild(int.Parse(index, CultureInfo.InvariantCulture));
                return node.GetComponent<ParticleSystem>();
            }).ToArray();
        }

        private static string AddressOf(Transform root, Transform node)
        {
            var indices = new Stack<int>();
            for (; node != root; node = node.parent) indices.Push(node.GetSiblingIndex());
            return string.Join("/", indices.Select(index => index.ToString(CultureInfo.InvariantCulture)));
        }
    }
}
