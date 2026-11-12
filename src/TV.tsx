import { useEffect, useMemo, useState } from 'react';
import { useEspelho, rotuloStatus } from './dados';
import { Predio, Resumo } from './Predio';
import { Aviso, StatusConexao, useAgora, useTitulo } from './Publico';

/** Modo TV do salão de vendas: tela cheia, leitura à distância, sem interação. */
export function TV() {
  const { unidades, config, carregando, erro, conectado, recentes } = useEspelho();
  const agora = useAgora(15_000);
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
        <h1 className="nome">{config?.nome_empreendimento}</h1>
        <Resumo unidades={unidades} grande />
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
