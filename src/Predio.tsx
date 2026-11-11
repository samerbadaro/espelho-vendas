import { type Unidade, type Status, STATUS, rotuloStatus, formatarArea, contar } from './dados';

interface Props {
  unidades: Unidade[];
  recentes: Record<string, number>;
  aoSelecionar?: (u: Unidade) => void;
}

const TEMPO_DESTAQUE = 6000;

/** Fachada do prédio: rooftop no topo, andares, e garagem/térreo/subsolo na base. */
function Faixa({ texto }: { texto: string }) {
  return <div className="andar" aria-hidden="true"><span /><div className="faixa">{texto}</div></div>;
}

export function Predio({ unidades, recentes, aoSelecionar }: Props) {
  const colunas = Math.max(0, ...unidades.map((u) => u.posicao));
  const andares = [...new Set(unidades.map((u) => u.andar))].sort((a, b) => b - a);
  const menorAndar = andares[andares.length - 1];
  const porAndar = new Map<number, Map<number, Unidade>>();
  unidades.forEach((u) => {
    if (!porAndar.has(u.andar)) porAndar.set(u.andar, new Map());
    porAndar.get(u.andar)!.set(u.posicao, u);
  });
  // área por coluna (final), usada no cabeçalho
  const areaColuna = (p: number) => unidades.find((u) => u.posicao === p && u.area_privativa != null)?.area_privativa ?? null;
  const agora = Date.now();

  return (
    <div className="predio" style={{ ['--colunas' as string]: colunas }} role="grid" aria-label="Espelho de unidades">
      <div className="predio-cabecalho" aria-hidden="true">
        <span className="rotulo-andar">m²</span>
        {Array.from({ length: colunas }, (_, i) => (
          <span key={i} className="area-coluna">
            {areaColuna(i + 1)?.toLocaleString('pt-BR', { minimumFractionDigits: 2 }) ?? ''}
          </span>
        ))}
      </div>
      <Faixa texto="Rooftop" />

      {andares.map((andar) => {
        const linha = porAndar.get(andar)!;
        const celulas = [];
        for (let p = 1; p <= colunas; p++) {
          const u = linha.get(p);
          if (u) {
            const destaque = recentes[u.id] && agora - recentes[u.id] < TEMPO_DESTAQUE;
            const conteudo = <span className="numero">{u.numero}</span>;
            const comum = {
              className: `unidade s-${u.status}${destaque ? ' mudou' : ''}`,
              title: `${u.numero}: ${rotuloStatus(u.status)}, ${formatarArea(u.area_privativa)}`,
              'aria-label': `Unidade ${u.numero}, ${rotuloStatus(u.status)}`,
            };
            celulas.push(
              aoSelecionar ? (
                <button key={u.id + (recentes[u.id] ?? '')} type="button" {...comum} onClick={() => aoSelecionar(u)}>
                  {conteudo}
                </button>
              ) : (
                <div key={u.id + (recentes[u.id] ?? '')} role="gridcell" {...comum}>{conteudo}</div>
              ),
            );
          } else {
            // posições vazias consecutivas viram um único bloco (ex.: lazer no 2º andar)
            let fim = p;
            while (fim + 1 <= colunas && !linha.get(fim + 1)) fim++;
            celulas.push(
              <div key={'vazio' + p} className="bloco-vazio" style={{ gridColumn: `span ${fim - p + 1}` }}>
                {andar === menorAndar ? 'Lazer' : ''}
              </div>,
            );
            p = fim;
          }
        }
        return (
          <div className="andar" key={andar} role="row">
            <span className="rotulo-andar">{andar}º</span>
            {celulas}
          </div>
        );
      })}

      <Faixa texto="Garagem" />
      <Faixa texto="Térreo" />
      <Faixa texto="Subsolo" />
    </div>
  );
}

/** Legenda com contagem por status. */
export function Resumo({ unidades, grande }: { unidades: Unidade[]; grande?: boolean }) {
  const c = contar(unidades);
  return (
    <ul className={`resumo${grande ? ' resumo-grande' : ''}`} aria-label="Legenda e totais">
      {STATUS.map((s) => (
        <li key={s.valor}>
          <span className={`amostra s-${s.valor}`} aria-hidden="true" />
          <span className="resumo-qtd">{c[s.valor as Status]}</span>
          <span className="resumo-rotulo">{c[s.valor as Status] === 1 ? s.rotulo : s.plural}</span>
        </li>
      ))}
    </ul>
  );
}
