import { useEffect, useState } from 'react';
import { useEspelho, type Unidade } from './dados';
import { Predio, Resumo } from './Predio';
import { Logo, useMarca } from './ui';

/** Página pública (link compartilhável). Sem login, sem dados de compradores. */
export function Publico() {
  const { unidades, config, carregando, erro, conectado, recentes } = useEspelho();
  const { marca } = useMarca();
  useTitulo(config?.nome_empreendimento);

  if (carregando) return <Aviso texto="Carregando o espelho…" />;
  if (erro && unidades.length === 0) return <Aviso texto={erro} />;
  if (config && !config.publico_ativo) return <Aviso texto="O espelho está fora do ar no momento. Fale com a equipe de vendas." />;

  return (
    <div className="pagina-publica">
      <header className="publico-topo">
        <div className="publico-marca">
          <Logo escuro />
          {marca.cidade && <span>{marca.cidade}</span>}
        </div>
      </header>
      <div className="publico-corpo">
        <div className="publico-titulo">
          <h1>Espelho de vendas</h1>
          <StatusConexao conectado={conectado} />
        </div>
        <div className="cartao espelho-cartao">
          <Resumo unidades={unidades} />
          <Predio unidades={unidades} recentes={recentes} />
        </div>
        <p className="rodape">Disponibilidade sujeita a confirmação pela equipe de vendas.</p>
      </div>
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
