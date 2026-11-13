import { useEffect, useMemo, useRef, useState } from 'react';
import { useEspelho, rotuloStatus, type Unidade } from './dados';
import { Predio, Resumo } from './Predio';
import { Aviso, StatusConexao, useAgora, useTitulo } from './Publico';
import { Logo, useMarca } from './ui';

/**
 * Na TV do salão só existem dois estados: disponível ou vendida.
 * Reservada, proposta, contrato, bloqueada e permutante aparecem como vendida.
 */
const paraTV = (u: Unidade): Unidade => (u.status === 'disponivel' ? u : { ...u, status: 'vendida' });

/** Modo TV do salão de vendas: tela cheia, leitura à distância, sem interação. */
export function TV() {
  const { unidades: reais, config, carregando, erro, conectado, recentes: recentesReais } = useEspelho();
  const unidades = useMemo(() => reais.map(paraTV), [reais]);

  // Só destaca na TV o que mudou do ponto de vista da TV (ex.: reservada -> proposta não aparece)
  const vistoNaTV = useRef<Map<string, string>>(new Map());
  const [recentes, setRecentes] = useState<Record<string, number>>({});
  useEffect(() => {
    const visto = vistoNaTV.current;
    const novos: Record<string, number> = {};
    unidades.forEach((u) => {
      const antes = visto.get(u.id);
      if (antes !== undefined && antes !== u.status && recentesReais[u.id]) novos[u.id] = recentesReais[u.id];
      visto.set(u.id, u.status);
    });
    if (Object.keys(novos).length) setRecentes((r) => ({ ...r, ...novos }));
  }, [unidades, recentesReais]);
  const agora = useAgora(15_000);
  const { marca } = useMarca();
  useTitulo(config?.nome_empreendimento);

  // Última movimentação recebida em tempo real (fica visível por 2 minutos)
  const ultima = useMemo(() => {
    const ids = Object.entries(recentes).sort((a, b) => b[1] - a[1]);
    if (!ids.length) return null;
    const [id, quando] = ids[0];
    const u = unidades.find((x) => x.id === id);
    return u ? { u, quando } : null;
  }, [recentes, unidades]);
  const [, forcar] = useState(0);
  useEffect(() => { const t = setInterval(() => forcar((x) => x + 1), 10_000); return () => clearInterval(t); }, []);

  if (carregando) return <Aviso texto="Carregando o espelho…" />;
  if (erro && unidades.length === 0) return <Aviso texto={erro} />;

  const mostrarUltima = ultima && Date.now() - ultima.quando < 120_000;

  return (
    <div className="tv">
      <main className="tv-predio">
        <Predio unidades={unidades} recentes={recentes} />
      </main>
      <aside className="tv-painel">
        <div className="tv-marca">
          {marca.logo_escuro_url || marca.logo_url ? <Logo escuro /> : <h1 className="nome">{config?.nome_empreendimento}</h1>}
          {marca.cidade && <span className="tv-cidade">{marca.cidade}</span>}
        </div>
        <Resumo unidades={unidades} grande apenas={['disponivel', 'vendida']} />
        {mostrarUltima && (
          <p className={`tv-ultima s-borda-${ultima!.u.status}`} key={ultima!.quando}>
            Unidade {ultima!.u.numero} agora está {rotuloStatus(ultima!.u.status).toLowerCase()}
          </p>
        )}
        <div className="tv-pe">
          <span className="tv-hora">
            {agora.toLocaleDateString('pt-BR')}, {agora.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
          </span>
          <StatusConexao conectado={conectado} />
        </div>
      </aside>
    </div>
  );
}
