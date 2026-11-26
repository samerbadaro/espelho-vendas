import { useEffect, useMemo, useRef, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { DUO_HAUS, type LayoutModelo } from './espelho3d/duohaus';
import { type Unidade, type Status, STATUS, rotuloStatus, formatarArea } from './dados';

/**
 * Espelho 3D: o prédio montado a partir das unidades (andar × posição), cada apartamento com a cor
 * do seu status, em tempo real. Maquete estilizada: metade das unidades do andar na fachada da frente,
 * a outra metade na de trás (corredor central). Clique abre o mesmo diálogo do espelho em tabela.
 */
interface Props {
  unidades: Unidade[];
  recentes: Record<string, number>;
  aoSelecionar?: (u: Unidade) => void;
}

// medidas da maquete (metros "de mentira", só proporção)
const LARG = 3.4;   // largura de um apartamento na fachada
const PE = 3.0;     // pé-direito
const PROF = 5.5;   // profundidade de um apartamento
const CORR = 1.8;   // corredor central
const TEMPO_DESTAQUE = 8000;

const corDoStatus = (s: Status) => {
  const v = getComputedStyle(document.documentElement).getPropertyValue(`--${s}`).trim();
  return new THREE.Color(v || '#888888');
};

interface Bloco { mesh: THREE.Mesh; unidade: Unidade }

/** Modelo real do prédio (.glb compactado em gzip), carregado uma vez por sessão. */
let modeloCache: Promise<THREE.Group> | null = null;
function carregarModelo(url: string): Promise<THREE.Group> {
  if (!modeloCache) {
    modeloCache = (async () => {
      const r = await fetch(url);
      if (!r.ok) throw new Error('modelo indisponível');
      let bytes = await r.arrayBuffer();
      const b0 = new Uint8Array(bytes, 0, 2);
      // alguns servidores já descompactam no caminho; só descompacta se ainda estiver em gzip
      if (b0[0] === 0x1f && b0[1] === 0x8b) {
        bytes = await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
      }
      const gltf = await new GLTFLoader().parseAsync(bytes, '');
      return gltf.scene;
    })();
    modeloCache.catch(() => { modeloCache = null; });
  }
  return modeloCache;
}

/** O layout do modelo serve se todas as unidades caem num andar e num vão conhecidos. */
const servePara = (l: LayoutModelo, us: Unidade[]) => us.length > 0 && us.every((u) => l.lajes[u.andar] != null && l.vaos[u.posicao]);

export default function Espelho3D({ unidades, recentes, aoSelecionar }: Props) {
  const caixa = useRef<HTMLDivElement>(null);
  const estado = useRef<{
    renderer?: THREE.WebGLRenderer; scene?: THREE.Scene; camera?: THREE.PerspectiveCamera; controls?: OrbitControls;
    blocos: Bloco[]; mats: Map<string, THREE.MeshStandardMaterial>; predio?: THREE.Group; frame?: number; centro?: THREE.Vector3;
  }>({ blocos: [], mats: new Map() });
  const [dica, setDica] = useState<{ x: number; y: number; u: Unidade } | null>(null);
  const [girando, setGirando] = useState(false);
  const [filtro, setFiltro] = useState<Status | null>(null);
  const [carregando, setCarregando] = useState(false);
  const selRef = useRef(aoSelecionar); selRef.current = aoSelecionar;
  const recRef = useRef(recentes); recRef.current = recentes;
  const filtroRef = useRef(filtro); filtroRef.current = filtro;

  // forma do prédio: muda só quando muda a lista de andares/posições
  const forma = useMemo(() => unidades.map((u) => `${u.id}:${u.andar}:${u.posicao}`).join('|'), [unidades]);

  // cena, câmera, luzes e controles (uma vez)
  useEffect(() => {
    const el = caixa.current!;
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(el.clientWidth, el.clientHeight);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    el.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    scene.background = new THREE.Color('#0e1626');
    scene.fog = new THREE.Fog('#0e1626', 140, 330);
    scene.add(new THREE.HemisphereLight('#c9d6ff', '#202530', 1.1));
    const sol = new THREE.DirectionalLight('#fff2dd', 1.6);
    sol.position.set(40, 80, 50);
    scene.add(sol);
    const contra = new THREE.DirectionalLight('#7f9cff', 0.5);
    contra.position.set(-50, 30, -40);
    scene.add(contra);

    // chão e entorno discreto
    const chao = new THREE.Mesh(new THREE.CircleGeometry(260, 64), new THREE.MeshStandardMaterial({ color: '#1a2233', roughness: 1 }));
    chao.rotation.x = -Math.PI / 2;
    scene.add(chao);
    const grade = new THREE.GridHelper(200, 50, '#2a3550', '#202a40');
    (grade.material as THREE.Material).transparent = true; (grade.material as THREE.Material).opacity = 0.5;
    scene.add(grade);

    // cidade ao fundo: prédios escuros com janelas acesas (textura desenhada uma vez)
    const tela = document.createElement('canvas'); tela.width = 64; tela.height = 128;
    const g = tela.getContext('2d')!;
    g.fillStyle = '#121a2b'; g.fillRect(0, 0, 64, 128);
    for (let y = 4; y < 124; y += 8) for (let x = 4; x < 60; x += 8) {
      const r = Math.random();
      g.fillStyle = r > 0.62 ? (r > 0.9 ? '#ffd28a' : '#f6b860') : r > 0.5 ? '#6f8fd6' : '#1b2540';
      g.fillRect(x, y, 4, 5);
    }
    const janelas = new THREE.CanvasTexture(tela);
    janelas.colorSpace = THREE.SRGBColorSpace;
    janelas.wrapS = janelas.wrapT = THREE.RepeatWrapping;
    for (let i = 0; i < 70; i++) {
      const ang = (i / 70) * Math.PI * 2 + Math.random() * 0.08;
      const raio = 125 + Math.random() * 70;
      const alt = 10 + Math.random() * 45, lad = 8 + Math.random() * 10;
      const t = janelas.clone(); t.repeat.set(lad / 8, alt / 16); t.needsUpdate = true;
      const m = new THREE.MeshStandardMaterial({ color: '#0c1220', emissive: '#ffffff', emissiveMap: t, emissiveIntensity: 0.9, roughness: 1 });
      const p = new THREE.Mesh(new THREE.BoxGeometry(lad, alt, lad), m);
      p.position.set(Math.cos(ang) * raio, alt / 2, Math.sin(ang) * raio);
      scene.add(p);
    }

    const camera = new THREE.PerspectiveCamera(40, el.clientWidth / el.clientHeight, 0.5, 800);
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.maxPolarAngle = Math.PI / 2 - 0.03;
    controls.minDistance = 15; controls.maxDistance = 160;
    controls.autoRotateSpeed = 0.8;

    estado.current = { ...estado.current, renderer, scene, camera, controls };

    const ray = new THREE.Raycaster();
    const ponteiro = new THREE.Vector2();
    let inicio = { x: 0, y: 0 };
    const acertar = (ev: PointerEvent) => {
      const r = renderer.domElement.getBoundingClientRect();
      ponteiro.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
      ray.setFromCamera(ponteiro, camera);
      const hit = ray.intersectObjects(estado.current.blocos.map((b) => b.mesh), false)[0];
      return hit ? estado.current.blocos.find((b) => b.mesh === hit.object) ?? null : null;
    };
    const mover = (ev: PointerEvent) => {
      const b = acertar(ev);
      const r = el.getBoundingClientRect();
      setDica(b ? { x: ev.clientX - r.left, y: ev.clientY - r.top, u: b.unidade } : null);
      renderer.domElement.style.cursor = b && selRef.current ? 'pointer' : 'grab';
    };
    const descer = (ev: PointerEvent) => { inicio = { x: ev.clientX, y: ev.clientY }; };
    const subir = (ev: PointerEvent) => {
      if (Math.hypot(ev.clientX - inicio.x, ev.clientY - inicio.y) > 6) return; // foi arrasto, não clique
      const b = acertar(ev);
      if (b && selRef.current) selRef.current(b.unidade);
    };
    renderer.domElement.addEventListener('pointermove', mover);
    renderer.domElement.addEventListener('pointerdown', descer);
    renderer.domElement.addEventListener('pointerup', subir);
    renderer.domElement.addEventListener('pointerleave', () => setDica(null));

    const redimensionar = () => {
      renderer.setSize(el.clientWidth, el.clientHeight);
      camera.aspect = el.clientWidth / Math.max(1, el.clientHeight);
      camera.updateProjectionMatrix();
    };
    const obs = new ResizeObserver(redimensionar);
    obs.observe(el);

    const relogio = new THREE.Clock();
    const animar = () => {
      estado.current.frame = requestAnimationFrame(animar);
      const t = relogio.getElapsedTime();
      const agora = Date.now();
      // unidades que mudaram há pouco piscam
      for (const b of estado.current.blocos) {
        const m = b.mesh.material as THREE.MeshStandardMaterial;
        const quando = recRef.current[b.unidade.id];
        const apagada = filtroRef.current && b.unidade.status !== filtroRef.current;
        m.emissiveIntensity = apagada ? 0.05 : quando && agora - quando < TEMPO_DESTAQUE ? 0.6 + 0.6 * Math.sin(t * 8) : 0.55;
        m.opacity = apagada ? 0.25 : 1;
      }
      controls.update();
      renderer.render(scene, camera);
    };
    animar();

    return () => {
      cancelAnimationFrame(estado.current.frame ?? 0);
      obs.disconnect();
      controls.dispose();
      scene.traverse((o) => {
        const m = o as THREE.Mesh;
        m.geometry?.dispose?.();
        const mat = m.material as THREE.Material | THREE.Material[] | undefined;
        if (Array.isArray(mat)) mat.forEach((x) => x.dispose()); else mat?.dispose?.();
      });
      renderer.dispose();
      el.removeChild(renderer.domElement);
    };
  }, []);

  // monta o prédio quando muda a forma (andares/posições)
  useEffect(() => {
    const { scene, camera, controls } = estado.current;
    if (!scene || !camera || !controls) return;
    if (estado.current.predio) { scene.remove(estado.current.predio); }
    let cancelado = false;
    if (servePara(DUO_HAUS, unidades)) {
      setCarregando(true);
      carregarModelo(DUO_HAUS.url).then((modelo) => {
        if (cancelado) return;
        montarNoModelo(modelo, DUO_HAUS);
      }).catch(() => { if (!cancelado) montarBlocos(); }).finally(() => { if (!cancelado) setCarregando(false); });
      return () => { cancelado = true; };
    }
    montarBlocos();
    return () => { cancelado = true; };

    /** Fachada real: o modelo do estúdio, com um vidro colorido em cada apartamento. */
    function montarNoModelo(modelo: THREE.Group, l: LayoutModelo) {
      const predio = new THREE.Group();
      // modelo em Z para cima (metros) -> tela em Y para cima: (x, y, z) => (x, z, -y)
      const casca = modelo.clone();
      casca.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) {
          const mat = (m.material as THREE.MeshStandardMaterial).clone();
          mat.roughness = 0.8; mat.metalness = 0;
          m.material = mat;
        }
      });
      predio.add(casca);
      const geo = new THREE.BoxGeometry(1, 1, 0.08);
      const blocos: Bloco[] = [];
      const mats = new Map<string, THREE.MeshStandardMaterial>();
      for (const u of unidades) {
        const v = l.vaos[u.posicao]; const z = l.lajes[u.andar];
        const cor = corDoStatus(u.status);
        const mat = new THREE.MeshStandardMaterial({ color: cor.clone().multiplyScalar(0.55), emissive: cor, emissiveIntensity: 0.55, roughness: 0.3, transparent: true });
        mats.set(u.id, mat);
        const mesh = new THREE.Mesh(geo, mat);
        mesh.scale.set(Math.max(0.6, v.x1 - v.x0 - 0.3), l.peDireito - 0.75, 1);
        // um pouco para fora do vidro, no lado da fachada
        mesh.position.set((v.x0 + v.x1) / 2, z + 0.15 + (l.peDireito - 0.75) / 2, -(v.y + v.lado * 0.14));
        predio.add(mesh);
        blocos.push({ mesh, unidade: u });
      }
      scene!.add(predio);
      estado.current.predio = predio;
      estado.current.blocos = blocos;
      estado.current.mats = mats;
      const caixaP = new THREE.Box3().setFromObject(casca);
      const centro = caixaP.getCenter(new THREE.Vector3());
      estado.current.centro = centro;
      const tam = caixaP.getSize(new THREE.Vector3());
      camera!.position.set(centro.x - tam.y * 0.6, centro.y * 0.8, centro.z + tam.y * 1.45);
      controls!.target.copy(centro);
      controls!.update();
    }

    function montarBlocos() {
    const predio = new THREE.Group();
    const andares = [...new Set(unidades.map((u) => u.andar))].sort((a, b) => a - b);
    if (!andares.length) return;
    const porAndar = Math.max(1, ...unidades.map((u) => u.posicao));
    const frente = Math.ceil(porAndar / 2);
    const largura = frente * LARG;
    const fundo = PROF * 2 + CORR;
    const base = andares[0];
    const alturaAndar = (a: number) => (a - base + 1) * PE; // térreo ocupa o primeiro "andar"
    const topo = alturaAndar(andares[andares.length - 1]) + PE;

    const fachada = new THREE.MeshStandardMaterial({ color: '#d8d0c2', roughness: 0.85 });
    const laje = new THREE.MeshStandardMaterial({ color: '#efe9dd', roughness: 0.7 });
    const vidroTerreo = new THREE.MeshStandardMaterial({ color: '#1d2b44', emissive: '#f2c97a', emissiveIntensity: 0.25, roughness: 0.3 });

    // núcleo (corredor/estrutura) e térreo
    const nucleo = new THREE.Mesh(new THREE.BoxGeometry(largura, topo - PE, CORR), fachada);
    nucleo.position.set(0, PE + (topo - PE) / 2, 0);
    predio.add(nucleo);
    const terreo = new THREE.Mesh(new THREE.BoxGeometry(largura + 0.6, PE, fundo + 0.6), vidroTerreo);
    terreo.position.set(0, PE / 2, 0);
    predio.add(terreo);
    const cobertura = new THREE.Mesh(new THREE.BoxGeometry(largura + 0.8, 0.6, fundo + 0.8), laje);
    cobertura.position.set(0, topo + 0.3, 0);
    predio.add(cobertura);
    const casaMaq = new THREE.Mesh(new THREE.BoxGeometry(largura * 0.3, PE * 0.9, CORR + 2), fachada);
    casaMaq.position.set(0, topo + 0.6 + PE * 0.45, 0);
    predio.add(casaMaq);

    // empenas laterais
    for (const lado of [-1, 1]) {
      const empena = new THREE.Mesh(new THREE.BoxGeometry(0.5, topo - PE, fundo + 0.4), fachada);
      empena.position.set(lado * (largura / 2 + 0.25), PE + (topo - PE) / 2, 0);
      predio.add(empena);
    }

    // materiais por status (compartilhados; o destaque mexe na intensidade)
    const mats = new Map<string, THREE.MeshStandardMaterial>();
    const blocos: Bloco[] = [];
    const geoMoldura = new THREE.BoxGeometry(LARG, PE, PROF - 0.2);
    const geoVidro = new THREE.BoxGeometry(LARG * 0.74, PE * 0.7, 0.2);
    const geoSacada = new THREE.BoxGeometry(LARG * 0.86, 0.14, 0.9);
    const geoGuarda = new THREE.BoxGeometry(LARG * 0.86, 0.55, 0.05);
    const guardaMat = new THREE.MeshStandardMaterial({ color: '#9fb6d6', transparent: true, opacity: 0.35, roughness: 0.1 });
    for (const u of unidades) {
      // cada unidade tem o seu material (para piscar e apagar sozinha)
      const cor = corDoStatus(u.status);
      const mat = new THREE.MeshStandardMaterial({ color: cor.clone().multiplyScalar(0.55), emissive: cor, emissiveIntensity: 0.55, roughness: 0.35, metalness: 0.1, transparent: true });
      mats.set(u.id, mat);
      const naFrente = u.posicao <= frente;
      const idx = naFrente ? u.posicao - 1 : porAndar - u.posicao; // a numeração dá a volta no prédio
      const x = -largura / 2 + LARG / 2 + idx * LARG;
      const lado = naFrente ? 1 : -1;
      const z = lado * (CORR / 2 + PROF / 2);
      const y = alturaAndar(u.andar) + PE / 2;
      const moldura = new THREE.Mesh(geoMoldura, fachada);
      moldura.position.set(x, y, z);
      predio.add(moldura);
      // vidro com a cor do status: é nele que se passa o mouse e clica
      const mesh = new THREE.Mesh(geoVidro, mat);
      mesh.position.set(x, y + 0.05, lado * (CORR / 2 + PROF - 0.05));
      predio.add(mesh);
      const sacada = new THREE.Mesh(geoSacada, laje);
      sacada.position.set(x, y - PE / 2 + 0.07, lado * (CORR / 2 + PROF + 0.35));
      predio.add(sacada);
      const guarda = new THREE.Mesh(geoGuarda, guardaMat);
      guarda.position.set(x, y - PE / 2 + 0.4, lado * (CORR / 2 + PROF + 0.78));
      predio.add(guarda);
      blocos.push({ mesh, unidade: u });
    }
    // lajes de cada andar
    for (const a of andares) {
      const l = new THREE.Mesh(new THREE.BoxGeometry(largura + 0.3, 0.18, fundo + 0.2), laje);
      l.position.set(0, alturaAndar(a), 0);
      predio.add(l);
    }

    scene!.add(predio);
    estado.current.predio = predio;
    estado.current.blocos = blocos;
    estado.current.mats = mats;
    const centro = new THREE.Vector3(0, topo / 2, 0);
    estado.current.centro = centro;
    const dist = Math.max(topo, largura) * 1.6;
    camera!.position.set(dist * 0.75, topo * 0.55, dist * 0.9);
    controls!.target.copy(centro);
    controls!.update();
    }
  }, [forma]); // eslint-disable-line react-hooks/exhaustive-deps

  // cor em tempo real, sem remontar o prédio
  useEffect(() => {
    const { blocos } = estado.current;
    const porId = new Map(unidades.map((u) => [u.id, u]));
    for (const b of blocos) {
      const u = porId.get(b.unidade.id);
      if (!u) continue;
      b.unidade = u;
      const cor = corDoStatus(u.status);
      const m = b.mesh.material as THREE.MeshStandardMaterial;
      m.color.copy(cor).multiplyScalar(0.55);
      m.emissive.copy(cor);
    }
  }, [unidades]);

  useEffect(() => { if (estado.current.controls) estado.current.controls.autoRotate = girando; }, [girando]);

  const centralizar = () => {
    const { camera, controls, centro, predio } = estado.current;
    if (!camera || !controls || !centro || !predio) return;
    const caixaP = new THREE.Box3().setFromObject(predio);
    const tam = caixaP.getSize(new THREE.Vector3());
    const dist = Math.max(tam.y, tam.x) * 1.6;
    camera.position.set(dist * 0.75, tam.y * 0.55, dist * 0.9);
    controls.target.copy(centro);
  };

  const contagem = useMemo(() => {
    const c = new Map<Status, number>();
    unidades.forEach((u) => c.set(u.status, (c.get(u.status) ?? 0) + 1));
    return c;
  }, [unidades]);

  return (
    <div className="espelho3d">
      <div ref={caixa} className="espelho3d-tela" />
      {carregando && <div className="espelho3d-carregando">Carregando a fachada do prédio…</div>}
      {dica && (
        <div className="espelho3d-dica" style={{ left: dica.x + 14, top: dica.y + 14 }}>
          <strong>Apto {dica.u.numero}</strong>
          <span>{[dica.u.tipologia, formatarArea(dica.u.area_privativa)].filter(Boolean).join(' · ')}</span>
          <span className={`etiqueta s-${dica.u.status}`}>{rotuloStatus(dica.u.status)}</span>
        </div>
      )}
      <div className="espelho3d-botoes">
        <button type="button" className="botao pequeno" onClick={() => setGirando((g) => !g)}>{girando ? 'Parar giro' : 'Girar'}</button>
        <button type="button" className="botao pequeno" onClick={centralizar}>Centralizar</button>
      </div>
      <div className="espelho3d-legenda">
        {STATUS.filter((s) => contagem.get(s.valor)).map((s) => (
          <button key={s.valor} type="button" className={`espelho3d-item ${filtro === s.valor ? 'ativo' : ''}`}
            onClick={() => setFiltro((f) => (f === s.valor ? null : s.valor))} title="Clique para destacar só este status">
            <i className={`s-${s.valor}`} />{s.plural} <b>{contagem.get(s.valor)}</b>
          </button>
        ))}
      </div>
      <p className="espelho3d-ajuda">Arraste para girar, use a roda ou dois dedos para aproximar{aoSelecionar ? ' e clique num apartamento para abrir' : ''}.</p>
    </div>
  );
}
