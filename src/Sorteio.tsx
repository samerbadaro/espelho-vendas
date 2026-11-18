// Sorteio do Meeting: tela cheia para o telão. O banco escolhe o ganhador entre os presentes
// com número que ainda não foram sorteados; a tela só faz a animação e mostra o resultado.
import { useCallback, useEffect, useRef, useState } from 'react';
import { Expand, Gift, RotateCcw, Shrink, UserX, X } from 'lucide-react';
import { supabase } from './dados';
import { useDialogos, useMarca } from './ui';

interface Sorteado { id: string; ordem: number; numero: number; nome: string; imobiliaria: string | null; premio: string | null; status: 'valido' | 'ausente'; sorteado_em: string }

const ERROS: Record<string, string> = {
  SEM_PARTICIPANTES_PARA_SORTEIO: 'Não há mais presentes para sortear: todos os confirmados já foram sorteados.',
  SEM_PERMISSAO: 'Sem permissão para sortear.',
  MEETING_NAO_ENCONTRADO: 'Meeting não encontrado.',
};

export function Sorteio({ eventoId, nomeMeeting, aoFechar }: { eventoId: string; nomeMeeting: string; aoFechar: () => void }) {
  const { avisar } = useDialogos();
  const { marca } = useMarca();
  const [numeros, setNumeros] = useState<number[]>([]);
  const [historico, setHistorico] = useState<Sorteado[]>([]);
  const [premio, setPremio] = useState('');
  const [girando, setGirando] = useState(false);
  const [mostrador, setMostrador] = useState<number | null>(null);
  const [ganhador, setGanhador] = useState<Sorteado | null>(null);
  const [cheia, setCheia] = useState(false);
  const raiz = useRef<HTMLDivElement>(null);

  const carregar = useCallback(async () => {
    const [p, s] = await Promise.all([
      supabase.from('recepcao_participantes').select('numero').eq('evento_id', eventoId).eq('presente', true).not('numero', 'is', null),
      supabase.from('meeting_sorteios').select('*').eq('evento_id', eventoId).order('ordem', { ascending: false }),
    ]);
    setNumeros(((p.data ?? []) as { numero: number }[]).map((x) => x.numero).sort((a, b) => a - b));
    setHistorico((s.data ?? []) as Sorteado[]);
  }, [eventoId]);
  useEffect(() => { carregar(); }, [carregar]);

  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape' && !document.fullscreenElement && !girando) aoFechar(); };
    const fs = () => setCheia(!!document.fullscreenElement);
    window.addEventListener('keydown', esc); document.addEventListener('fullscreenchange', fs);
    return () => { window.removeEventListener('keydown', esc); document.removeEventListener('fullscreenchange', fs); };
  }, [aoFechar, girando]);

  const jaSorteados = new Set(historico.map((h) => h.numero));
  const concorrendo = numeros.filter((n) => !jaSorteados.has(n));

  const sortear = async () => {
    if (girando) return;
    if (!concorrendo.length) { avisar(ERROS.SEM_PARTICIPANTES_PARA_SORTEIO, 'erro'); return; }
    setGirando(true); setGanhador(null);
    const pedido = supabase.rpc('sortear_meeting', { p_evento: eventoId, p_premio: premio || null });
    // números passando: rápido no começo, desacelerando até o resultado (cerca de 3,5 s)
    const pool = concorrendo;
    let atraso = 45;
    const inicio = Date.now();
    await new Promise<void>((pronto) => {
      const passo = () => {
        setMostrador(pool[Math.floor(Math.random() * pool.length)]);
        if (Date.now() - inicio > 2600) atraso *= 1.18;
        if (Date.now() - inicio > 3500) { pronto(); return; }
        setTimeout(passo, atraso);
      };
      passo();
    });
    const { data, error } = await pedido;
    setGirando(false);
    if (error) {
      setMostrador(null);
      avisar(ERROS[Object.keys(ERROS).find((k) => error.message.includes(k)) ?? ''] ?? 'Não foi possível sortear. Tente de novo.', 'erro');
      carregar();
      return;
    }
    const g = data as Sorteado;
    setMostrador(g.numero); setGanhador(g);
    setHistorico((h) => [g, ...h]);
  };

  const ausente = async (g: Sorteado) => {
    const { error } = await supabase.rpc('sorteio_ausente', { p_id: g.id });
    if (error) { avisar('Não foi possível registrar.', 'erro'); return; }
    setHistorico((h) => h.map((x) => (x.id === g.id ? { ...x, status: 'ausente' } : x)));
    setGanhador(null); setMostrador(null);
    sortear();
  };

  const telaCheia = async () => {
    try { if (document.fullscreenElement) await document.exitFullscreen(); else await raiz.current?.requestFullscreen(); } catch { /* navegador não deixou */ }
  };

  return (
    <div className="sorteio" ref={raiz} role="dialog" aria-modal="true" aria-label="Sorteio">
      <div className="sorteio-topo">
        <div className="sorteio-marca">
          {marca.logo_escuro_url ? <img src={marca.logo_escuro_url} alt="" /> : null}
          <span>{nomeMeeting}</span>
        </div>
        <div className="sorteio-botoes">
          <button className="sorteio-icone" onClick={telaCheia} title={cheia ? 'Sair da tela cheia' : 'Tela cheia'} aria-label="Tela cheia">{cheia ? <Shrink size={20} /> : <Expand size={20} />}</button>
          <button className="sorteio-icone" onClick={aoFechar} disabled={girando} title="Fechar" aria-label="Fechar"><X size={22} /></button>
        </div>
      </div>

      <div className="sorteio-palco">
        <div className="sorteio-premio">
          <Gift size={22} />
          <input value={premio} onChange={(e) => setPremio(e.target.value)} placeholder="Prêmio (opcional)" disabled={girando} aria-label="Prêmio" />
        </div>
        <div className={`sorteio-numero${girando ? ' girando' : ''}${ganhador ? ' ganhou' : ''}`} aria-live="polite">
          {mostrador ?? '?'}
        </div>
        <div className="sorteio-ganhador">
          {ganhador ? (
            <>
              <strong>{ganhador.nome}</strong>
              {ganhador.imobiliaria && <span>{ganhador.imobiliaria}</span>}
              {ganhador.premio && <em>{ganhador.premio}</em>}
            </>
          ) : <span className="sorteio-concorrendo">{girando ? 'Sorteando…' : `${concorrendo.length} ${concorrendo.length === 1 ? 'pessoa concorrendo' : 'pessoas concorrendo'}`}</span>}
        </div>
        <div className="sorteio-acoes">
          <button className="sorteio-sortear" onClick={sortear} disabled={girando || !concorrendo.length}>
            {ganhador ? <><RotateCcw size={20} /> Sortear outro</> : 'Sortear'}
          </button>
          {ganhador && !girando && (
            <button className="sorteio-ausente" onClick={() => ausente(ganhador)} title="Registra como ausente e sorteia de novo">
              <UserX size={18} /> Não está presente, sortear de novo
            </button>
          )}
        </div>
      </div>

      {historico.length > 0 && (
        <aside className="sorteio-historico">
          <h3>Sorteados</h3>
          <ol>
            {historico.map((h) => (
              <li key={h.id} className={h.status === 'ausente' ? 'ausente' : ''}>
                <span className="sorteio-h-num">{h.numero}</span>
                <span className="sorteio-h-nome"><strong>{h.nome}</strong>{h.premio ? ` · ${h.premio}` : ''}{h.status === 'ausente' ? ' · ausente' : ''}</span>
              </li>
            ))}
          </ol>
        </aside>
      )}
    </div>
  );
}
