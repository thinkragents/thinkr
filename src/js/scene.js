/* ===========================================================
   The hero scene. Procedural: no textures, no image assets.
   Starfield, nebula, four mountain silhouettes, atmosphere,
   ACES tone mapping and a bloom pass. The camera flies through
   it on scroll and the exposure lifts as you descend.

   Ported from the original Thinkr hero.
   =========================================================== */

import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';

const NEON = 0xcdf03a;

export function initScene(canvas) {
  if (!canvas) return null;
  /* bloom and exposure read far too hot on a small screen */
  const DIM = window.innerWidth < 760 ? 0.55 : 1;

  const scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x000000, 0.00025);

  const camera = new THREE.PerspectiveCamera(75, innerWidth / innerHeight, 0.1, 2000);
  camera.position.set(0, 20, 100);

  /* A backdrop under a dark scrim, finished with bloom: retina pixels and
     antialiasing are invisible here and cost four times the fill. One pixel
     ratio and no MSAA, on a default power GPU. */
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: true, powerPreference: 'default' });
  renderer.setSize(innerWidth, innerHeight);
  renderer.setPixelRatio(1);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.40 * DIM;

  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), 0.22 * DIM, 0.75, 0.96);
  composer.addPass(bloom);

  /* --- stars, three depth layers ---------------------------- */
  const stars = [];
  for (let layer = 0; layer < 3; layer++) {
    const count = 1700;
    const pos = new Float32Array(count * 3);
    const col = new Float32Array(count * 3);
    const siz = new Float32Array(count);
    const c = new THREE.Color();
    for (let i = 0; i < count; i++) {
      pos[i * 3] = (Math.random() - 0.5) * 2000;
      pos[i * 3 + 1] = (Math.random() - 0.5) * 2000;
      pos[i * 3 + 2] = (Math.random() - 0.5) * 2000 - layer * 400;
      /* mostly cold white, a few on the brand hue */
      if (Math.random() > 0.9) c.setHex(NEON);
      else c.setHSL(0.3, 0.1, 0.6 + Math.random() * 0.4);
      col[i * 3] = c.r; col[i * 3 + 1] = c.g; col[i * 3 + 2] = c.b;
      siz[i] = Math.random() * 2 + 0.4;
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('color', new THREE.BufferAttribute(col, 3));
    g.setAttribute('size', new THREE.BufferAttribute(siz, 1));
    const m = new THREE.ShaderMaterial({
      uniforms: { time: { value: 0 }, depth: { value: layer } },
      vertexShader: `
        attribute float size; attribute vec3 color; varying vec3 vColor;
        uniform float time; uniform float depth;
        void main() {
          vColor = color; vec3 p = position;
          float a = time * 0.05 * (1.0 - depth * 0.3);
          mat2 rot = mat2(cos(a), -sin(a), sin(a), cos(a));
          p.xy = rot * p.xy;
          vec4 mv = modelViewMatrix * vec4(p, 1.0);
          gl_PointSize = size * (300.0 / -mv.z);
          gl_Position = projectionMatrix * mv;
        }`,
      fragmentShader: `
        varying vec3 vColor;
        void main() {
          float d = length(gl_PointCoord - vec2(0.5));
          if (d > 0.5) discard;
          gl_FragColor = vec4(vColor, 1.0 - smoothstep(0.0, 0.5, d));
        }`,
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
    });
    const pts = new THREE.Points(g, m);
    scene.add(pts); stars.push(pts);
  }

  /* --- nebula ------------------------------------------------ */
  const nebula = new THREE.Mesh(
    new THREE.PlaneGeometry(8000, 4000, 100, 100),
    new THREE.ShaderMaterial({
      uniforms: {
        time: { value: 0 },
        color1: { value: new THREE.Color(NEON) },
        color2: { value: new THREE.Color(0x0a3a1e) },
        opacity: { value: 0.12 },
      },
      vertexShader: `
        varying vec2 vUv; varying float vE; uniform float time;
        void main() {
          vUv = uv; vec3 p = position;
          float e = sin(p.x * 0.01 + time) * cos(p.y * 0.01 + time) * 20.0;
          p.z += e; vE = e;
          gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
        }`,
      fragmentShader: `
        uniform vec3 color1; uniform vec3 color2; uniform float opacity;
        varying vec2 vUv; varying float vE;
        void main() {
          float m = smoothstep(-20.0, 20.0, vE);
          vec3 c = mix(color2, color1, m * 0.5);
          float edge = 1.0 - length(vUv - 0.5) * 2.0;
          gl_FragColor = vec4(c, opacity * clamp(edge, 0.0, 1.0));
        }`,
      transparent: true, side: THREE.DoubleSide, depthWrite: false,
    })
  );
  nebula.position.z = -1050;
  scene.add(nebula);

  /* --- mountains, four silhouette layers --------------------- */
  const mountains = [];
  [
    { distance: -60,  height: 78,  color: 0x05060a, opacity: 1 },
    { distance: -110, height: 96,  color: 0x070810, opacity: 0.9 },
    { distance: -160, height: 118, color: 0x090b14, opacity: 0.7 },
    { distance: -210, height: 140, color: 0x0b0d18, opacity: 0.48 },
  ].forEach((layer, index) => {
    const pts = [];
    const segments = 50;
    for (let i = 0; i <= segments; i++) {
      const x = (i / segments - 0.5) * 1000;
      const y =
        Math.sin(i * 0.1) * layer.height +
        Math.sin(i * 0.05) * layer.height * 0.5 +
        Math.random() * layer.height * 0.2 - 112;
      pts.push(new THREE.Vector2(x, y));
    }
    pts.push(new THREE.Vector2(5000, -300));
    pts.push(new THREE.Vector2(-5000, -300));
    const mesh = new THREE.Mesh(
      new THREE.ShapeGeometry(new THREE.Shape(pts)),
      new THREE.MeshBasicMaterial({ color: layer.color, transparent: true, opacity: layer.opacity, side: THREE.DoubleSide })
    );
    mesh.position.z = layer.distance;
    mesh.userData = { baseZ: layer.distance, index };
    scene.add(mesh); mountains.push(mesh);
  });
  const locations = mountains.map((m) => m.position.z);

  /* --- atmosphere -------------------------------------------- */
  scene.add(new THREE.Mesh(
    new THREE.SphereGeometry(600, 32, 32),
    new THREE.ShaderMaterial({
      uniforms: { time: { value: 0 } },
      vertexShader: `varying vec3 vN;
        void main(){ vN = normalize(normalMatrix * normal);
          gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
      fragmentShader: `varying vec3 vN; uniform float time;
        void main(){
          float i = pow(max(0.0, 0.42 - dot(vN, vec3(0.0,0.0,1.0))), 4.2);
          vec3 a = vec3(0.80, 0.94, 0.23) * i;
          a *= sin(time * 2.0) * 0.05 + 0.95;
          gl_FragColor = vec4(a, i * 0.055);
        }`,
      side: THREE.BackSide, transparent: true, blending: THREE.AdditiveBlending,
    })
  ));

  /* --- camera path ------------------------------------------- */
  const PATH = [
    { x: 0, y: 20, z: 100 },
    { x: 0, y: 25, z: -100 },
    { x: 0, y: 35, z: -350 },
    { x: 0, y: 50, z: -700 },
    { x: 0, y: 60, z: -1400 },
  ];
  const smooth = { x: 0, y: 20, z: 100 };
  const target = { x: 0, y: 20, z: 100 };
  let exposure = 0.40 * DIM;
  let raf = null;

  function onScroll() {
    const max = document.documentElement.scrollHeight - innerHeight;
    const p = max > 0 ? Math.min(scrollY / max, 1) : 0;
    const steps = PATH.length - 1;
    const t = p * steps;
    const i = Math.min(Math.floor(t), steps - 1);
    const f = t - i;
    const a = PATH[i], b = PATH[i + 1];
    target.x = a.x + (b.x - a.x) * f;
    target.y = a.y + (b.y - a.y) * f;
    target.z = a.z + (b.z - a.z) * f;
    /* brighten as the camera descends */
    exposure = (0.40 + p * 0.45) * DIM;
    mountains.forEach((m, n) => {
      m.position.z = p > 0.7 ? 600000 : locations[n];
    });
    nebula.position.z = mountains[3].position.z;
  }

  /* a slow drift needs 30 frames, not the display's 60 or 120 */
  const FRAME_MS = 1000 / 30;
  let last = 0;

  function animate(now = performance.now()) {
    raf = requestAnimationFrame(animate);
    if (now - last < FRAME_MS) return;
    last = now;
    const time = Date.now() * 0.001;
    stars.forEach((s) => (s.material.uniforms.time.value = time));
    nebula.material.uniforms.time.value = time * 0.5;

    smooth.x += (target.x - smooth.x) * 0.05;
    smooth.y += (target.y - smooth.y) * 0.05;
    smooth.z += (target.z - smooth.z) * 0.05;
    /* a slow idle drift so it never sits perfectly still */
    camera.position.x = smooth.x + Math.sin(time * 0.1) * 2;
    camera.position.y = smooth.y + Math.cos(time * 0.15) * 1;
    camera.position.z = smooth.z;

    renderer.toneMappingExposure += (exposure - renderer.toneMappingExposure) * 0.05;
    composer.render();
  }

  function onResize() {
    camera.aspect = innerWidth / innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(innerWidth, innerHeight);
    composer.setSize(innerWidth, innerHeight);
  }

  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('resize', onResize);
  onScroll();
  animate();

  /* stop drawing when it is off screen */
  new IntersectionObserver(([e]) => {
    if (e.isIntersecting && !raf) animate();
    else if (!e.isIntersecting && raf) { cancelAnimationFrame(raf); raf = null; }
  }).observe(canvas);

  return { scene, camera, renderer };
}
