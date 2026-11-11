import { useEffect, useState } from 'react';
import { useEspelho, type Unidade } from './dados';
import { Predio, Resumo } from './Predio';

/** Página pública (link compartilhável). Sem login, sem dados de compradores. */
export function Publico() {
  const { unidades, config, carregando, erro, conectado, recentes } = useEspelho();
  useTitulo(config?.nome_empreendimento);

  if (carregando) return <Aviso texto="Carregando o espelho…" />;
  if (erro && unidades.length === 0) return <Aviso texto={erro} />;
  if (config && !config.publico_ativo) return <Aviso texto="O espelho está fora do ar no momento. Fale com a equipe de vendas." />;

  return (
    <div className="pagina-publica">
      <header className="topo">
        <h1 className="nome">{config?.nome_empreendimento}</h1>
        <StatusConexao conectado={conectado} />
      </header>
      <Resumo unidades={unidades} />
      <Predio unidades={unidades} recentes={recentes} />
      <p className="rodape">Disponibilidade sujeita a confirmação pela equipe de vendas.</p>
    </div>
  );
}

export function StatusConexao({ conectado }: { conectado: boolean }) {
  return (
    <span className={`conexao${conectado ? ' on' : ''}`}>
      {conectado ? 'Atualizando em tempo real' : 'Reconectando…'}
    </span>
  );
}

export function Aviso({ texto }: { texto: string }) {
  return <div className="aviso"><p>{texto}</p></div>;
}

export function useTitulo(nome?: string) {
  useEffect(() => { if (nome) document.title = nome; }, [nome]);
}

/** Relógio simples para a TV. */
export function useAgora(ms = 1000) {
  const [agora, setAgora] = useState(new Date());
  useEffect(() => { const t = setInterval(() => setAgora(new Date()), ms); return () => clearInterval(t); }, [ms]);
  return agora;
}

export type { Unidade };
