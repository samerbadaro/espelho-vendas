import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { supabase } from './dados';

// =====================================================================
// Marca do empreendimento (nome, cores, logos) — vem da tabela config
// =====================================================================
export interface Marca {
  nome_empreendimento: string;
  cidade: string | null;
  cor_primaria: string;
  cor_destaque: string;
  cor_apoio: string;
  fonte: string;
  logo_url: string | null;
  logo_escuro_url: string | null;
  imagem_login_url: string | null;
  modulo_pastas: boolean;
  publico_ativo: boolean;
}

const PADRAO: Marca = {
  nome_empreendimento: '', cidade: null, cor_primaria: '#23251C', cor_destaque: '#94874A', cor_apoio: '#CFCBC2', fonte: 'Archivo',
  logo_url: null, logo_escuro_url: null, imagem_login_url: null, modulo_pastas: true, publico_ativo: true,
};

/** Texto legível (claro ou escuro) sobre uma cor de fundo. */
export function textoSobre(hex: string) {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4 ? '#1B1C17' : '#FFFFFF';
}

export const FONTES = ['42dot Sans', 'Archivo', 'Manrope', 'DM Sans', 'Montserrat', 'Inter', 'Plus Jakarta Sans', 'Outfit'];

function carregarFonte(nome: string) {
  if (!/^[A-Za-z0-9 ]{2,40}$/.test(nome)) return;
  const id = 'fonte-marca-' + nome.replace(/ /g, '-');
  if (document.getElementById(id)) return;
  const link = document.createElement('link');
  link.id = id; link.rel = 'stylesheet';
  link.href = `https://fonts.googleapis.com/css2?family=${encodeURIComponent(nome).replace(/%20/g, '+')}:wght@300..800&display=swap`;
  document.head.appendChild(link);
}

export function aplicarMarca(m: Partial<Pick<Marca, 'cor_primaria' | 'cor_destaque' | 'cor_apoio' | 'fonte'>>) {
  const s = document.documentElement.style;
  if (m.cor_primaria) { s.setProperty('--primaria', m.cor_primaria); s.setProperty('--primaria-texto', textoSobre(m.cor_primaria)); }
  if (m.cor_destaque) { s.setProperty('--destaque', m.cor_destaque); s.setProperty('--destaque-texto', textoSobre(m.cor_destaque)); }
  if (m.cor_apoio) { s.setProperty('--apoio', m.cor_apoio); s.setProperty('--apoio-texto', textoSobre(m.cor_apoio)); }
  if (m.fonte) { carregarFonte(m.fonte); s.setProperty('--fonte', `'${m.fonte}', system-ui, sans-serif`); }
}

const MarcaCtx = createContext<{ marca: Marca; carregada: boolean; recarregar: () => void }>({
  marca: PADRAO, carregada: false, recarregar: () => {},
});

const CHAVE_CACHE = 'espelho-marca';
function marcaGuardada(): Marca {
  try {
    const m = { ...PADRAO, ...JSON.parse(localStorage.getItem(CHAVE_CACHE) || '{}') } as Marca;
    aplicarMarca(m);
    return m;
  } catch { return PADRAO; }
}

export function ProvedorMarca({ children }: { children: ReactNode }) {
  // usa a última marca conhecida para não piscar as cores padrão ao abrir
  const [marca, setMarca] = useState<Marca>(marcaGuardada);
  const [carregada, setCarregada] = useState(false);
  const recarregar = useCallback(() => {
    supabase.from('config')
      .select('*')
      .eq('id', 1).single()
      .then(({ data }) => {
        if (data) {
          const m = { ...PADRAO, ...(data as Partial<Marca>) };
          setMarca(m); aplicarMarca(m);
          try { localStorage.setItem(CHAVE_CACHE, JSON.stringify(m)); } catch { /* navegador sem armazenamento */ }
        }
        setCarregada(true);
      });
  }, []);
  useEffect(() => { recarregar(); }, [recarregar]);
  return <MarcaCtx.Provider value={{ marca, carregada, recarregar }}>{children}</MarcaCtx.Provider>;
}
export const useMarca = () => useContext(MarcaCtx);

/** Logo do empreendimento; sem logo cadastrado, mostra o nome. */
export function Logo({ escuro, className }: { escuro?: boolean; className?: string }) {
  const { marca } = useMarca();
  const src = escuro ? marca.logo_escuro_url || marca.logo_url : marca.logo_url;
  if (src) return <img className={`logo ${className ?? ''}`} src={src} alt={marca.nome_empreendimento} />;
  return <span className={`logo-texto ${className ?? ''}`}>{marca.nome_empreendimento}</span>;
}

// =====================================================================
// Confirmações e avisos do próprio sistema (substituem as janelas do navegador)
// =====================================================================
interface OpcoesConfirmar { titulo: string; texto?: string; confirmar?: string; perigo?: boolean }
interface Aviso { id: number; texto: string; tipo: 'ok' | 'erro' }

const DialogoCtx = createContext<{
  confirmar: (o: OpcoesConfirmar) => Promise<boolean>;
  avisar: (texto: string, tipo?: 'ok' | 'erro') => void;
}>({ confirmar: async () => false, avisar: () => {} });

export function ProvedorDialogos({ children }: { children: ReactNode }) {
  const [pedido, setPedido] = useState<(OpcoesConfirmar & { resolver: (v: boolean) => void }) | null>(null);
  const [avisos, setAvisos] = useState<Aviso[]>([]);
  const botao = useRef<HTMLButtonElement>(null);

  const confirmar = useCallback((o: OpcoesConfirmar) => new Promise<boolean>((resolver) => setPedido({ ...o, resolver })), []);
  const avisar = useCallback((texto: string, tipo: 'ok' | 'erro' = 'ok') => {
    const id = Date.now() + Math.random();
    setAvisos((a) => [...a, { id, texto, tipo }]);
    setTimeout(() => setAvisos((a) => a.filter((x) => x.id !== id)), tipo === 'erro' ? 7000 : 4000);
  }, []);
  const fechar = (v: boolean) => { pedido?.resolver(v); setPedido(null); };

  useEffect(() => {
    if (!pedido) return;
    botao.current?.focus();
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && fechar(false);
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <DialogoCtx.Provider value={{ confirmar, avisar }}>
      {children}
      {pedido && (
        <div className="fundo-dialogo" onClick={() => fechar(false)}>
          <div className="dialogo confirmacao" role="alertdialog" aria-modal="true" aria-labelledby="conf-titulo" onClick={(e) => e.stopPropagation()}>
            <h2 id="conf-titulo">{pedido.titulo}</h2>
            {pedido.texto && <p>{pedido.texto}</p>}
            <div className="dialogo-acoes">
              <button className="botao" onClick={() => fechar(false)}>Cancelar</button>
              <button ref={botao} className={`botao ${pedido.perigo ? 'perigo' : 'principal'}`} onClick={() => fechar(true)}>
                {pedido.confirmar ?? 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}
      <div className="avisos" aria-live="polite">
        {avisos.map((a) => <div key={a.id} className={`aviso-flutuante ${a.tipo}`}>{a.texto}</div>)}
      </div>
    </DialogoCtx.Provider>
  );
}
export const useDialogos = () => useContext(DialogoCtx);

// =====================================================================
// Encerra a sessão após um período sem uso (computadores compartilhados)
// =====================================================================
export function useSaidaPorInatividade(minutos: number, aoSair: () => void) {
  useEffect(() => {
    let t: ReturnType<typeof setTimeout>;
    const reiniciar = () => { clearTimeout(t); t = setTimeout(aoSair, minutos * 60_000); };
    const eventos = ['pointerdown', 'keydown', 'scroll', 'touchstart'];
    eventos.forEach((e) => window.addEventListener(e, reiniciar, { passive: true }));
    reiniciar();
    return () => { clearTimeout(t); eventos.forEach((e) => window.removeEventListener(e, reiniciar)); };
  }, [minutos, aoSair]);
}
