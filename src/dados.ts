import { createClient, type RealtimeChannel } from '@supabase/supabase-js';
import { useEffect, useRef, useState, useCallback } from 'react';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const chave = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const configurado = Boolean(url && chave);
export const supabase = createClient(url || 'http://localhost', chave || 'sem-chave');

export type Status = 'disponivel' | 'reservada' | 'vendida' | 'bloqueada';

export interface Unidade {
  id: string;
  numero: string;
  andar: number;
  posicao: number;
  area_privativa: number | null;
  tipologia: string | null;
  status: Status;
  versao: number;
  atualizado_em: string;
}

export interface Config {
  nome_empreendimento: string;
  publico_ativo: boolean;
}

export const STATUS: { valor: Status; rotulo: string; plural: string }[] = [
  { valor: 'disponivel', rotulo: 'Disponível', plural: 'Disponíveis' },
  { valor: 'reservada', rotulo: 'Reservada', plural: 'Reservadas' },
  { valor: 'vendida', rotulo: 'Vendida', plural: 'Vendidas' },
  { valor: 'bloqueada', rotulo: 'Bloqueada', plural: 'Bloqueadas' },
];
export const rotuloStatus = (s: Status) => STATUS.find((x) => x.valor === s)?.rotulo ?? s;

export const formatarArea = (a: number | null) =>
  a == null ? '—' : `${a.toLocaleString('pt-BR', { minimumFractionDigits: 2 })} m²`;

export const formatarDataHora = (iso: string) =>
  new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });

/**
 * Carrega unidades e configuração e mantém tudo sincronizado em tempo real.
 * Reforços para uso contínuo (TV do salão):
 *  - recarrega ao reconectar, ao voltar a aba para a frente e a cada 60 s;
 *  - recria a assinatura de tempo real se o canal cair.
 */
export function useEspelho() {
  const [unidades, setUnidades] = useState<Unidade[]>([]);
  const [config, setConfig] = useState<Config | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [conectado, setConectado] = useState(false);
  const [recentes, setRecentes] = useState<Record<string, number>>({});
  const canal = useRef<RealtimeChannel | null>(null);

  const carregar = useCallback(async () => {
    if (!configurado) {
      setErro('O sistema ainda não foi conectado ao banco de dados.');
      setCarregando(false);
      return;
    }
    const [u, c] = await Promise.all([
      supabase.from('unidades').select('*').order('andar', { ascending: false }).order('posicao'),
      supabase.from('config').select('nome_empreendimento, publico_ativo').eq('id', 1).single(),
    ]);
    if (u.error || c.error) {
      setErro('Não foi possível carregar o espelho. Tentando novamente…');
    } else {
      setErro(null);
      setUnidades(u.data as Unidade[]);
      setConfig(c.data as Config);
    }
    setCarregando(false);
  }, []);

  useEffect(() => {
    if (!configurado) { carregar(); return; }
    let ativo = true;
    let tentativa: ReturnType<typeof setTimeout> | undefined;

    const assinar = () => {
      if (canal.current) supabase.removeChannel(canal.current);
      canal.current = supabase
        .channel('espelho-' + Math.random().toString(36).slice(2))
        .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'unidades' }, (p) => {
          const nova = p.new as Unidade;
          setUnidades((lista) => lista.map((x) => (x.id === nova.id ? { ...x, ...nova } : x)));
          setRecentes((r) => ({ ...r, [nova.id]: Date.now() }));
        })
        .on('postgres_changes', { event: '*', schema: 'public', table: 'config' }, () => carregar())
        .subscribe((estado) => {
          if (!ativo) return;
          if (estado === 'SUBSCRIBED') { setConectado(true); carregar(); }
          if (estado === 'CHANNEL_ERROR' || estado === 'TIMED_OUT' || estado === 'CLOSED') {
            setConectado(false);
            clearTimeout(tentativa);
            tentativa = setTimeout(() => ativo && assinar(), 5000);
          }
        });
    };

    carregar();
    assinar();
    const intervalo = setInterval(carregar, 60_000);
    const aoVoltar = () => document.visibilityState === 'visible' && carregar();
    const aoReconectar = () => { carregar(); assinar(); };
    document.addEventListener('visibilitychange', aoVoltar);
    window.addEventListener('online', aoReconectar);
    const sessao = supabase.auth.onAuthStateChange(() => carregar());

    return () => {
      ativo = false;
      clearInterval(intervalo);
      clearTimeout(tentativa);
      document.removeEventListener('visibilitychange', aoVoltar);
      window.removeEventListener('online', aoReconectar);
      sessao.data.subscription.unsubscribe();
      if (canal.current) supabase.removeChannel(canal.current);
    };
  }, [carregar]);

  const atualizarLocal = (u: Unidade) => {
    setUnidades((lista) => lista.map((x) => (x.id === u.id ? u : x)));
    setRecentes((r) => ({ ...r, [u.id]: Date.now() }));
  };

  return { unidades, config, carregando, erro, conectado, recentes, recarregar: carregar, atualizarLocal };
}

export function contar(unidades: Unidade[]) {
  const c: Record<Status, number> = { disponivel: 0, reservada: 0, vendida: 0, bloqueada: 0 };
  unidades.forEach((u) => c[u.status]++);
  return c;
}
