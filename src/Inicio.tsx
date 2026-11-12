import { useEffect, useState, type ReactNode } from 'react';
import { LayoutGrid, FolderOpen, Building2, Tv, ArrowUpRight } from 'lucide-react';
import { supabase, useEspelho, contar, rotuloStatus, formatarDataHora, STATUS, type Status } from './dados';
import { ir, type Perfil } from './util';
import { useMarca } from './ui';

interface Indicadores {
  pastas: Record<string, number> | null;
  pastas_total: number;
  pastas_submetidas: number;
  vendas_7_dias: number;
  reservas_7_dias: number;
}
interface Mov { id: number; numero: string; status_anterior: Status | null; status_novo: Status; usuario_email: string | null; criado_em: string }

function saudacao() {
  const h = new Date().getHours();
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

/** Tela inicial da equipe: indicadores, atalhos e últimas movimentações. */
export function Inicio({ perfil }: { perfil: Perfil }) {
  const { marca } = useMarca();
  const esp = useEspelho();
  const [ind, setInd] = useState<Indicadores | null>(null);
  const [movs, setMovs] = useState<Mov[]>([]);
  const ultimaMudanca = Math.max(0, ...Object.values(esp.recentes));

  useEffect(() => {
    supabase.rpc('indicadores').then(({ data }) => setInd((data as Indicadores) ?? null));
    supabase.from('historico').select('id, numero, status_anterior, status_novo, usuario_email, criado_em')
      .order('criado_em', { ascending: false }).limit(6)
      .then(({ data }) => setMovs((data as Mov[]) ?? []));
  }, [ultimaMudanca]);

  const c = contar(esp.unidades);
  const total = esp.unidades.length;
  const negociacao = c.reservada + c.proposta + c.contrato;
  const p = ind?.pastas ?? {};
  const n = (k: string) => p[k] ?? 0;
  const primeiroNome = (perfil.nome || '').split(' ')[0];

  return (
    <section className="secao inicio">
      <div className="secao-topo">
        <div>
          <h2>{saudacao()}{primeiroNome ? `, ${primeiroNome}` : ''}</h2>
          <p className="sub">{marca.nome_empreendimento}{marca.cidade ? `, ${marca.cidade}` : ''}</p>
        </div>
      </div>

      <div className="cartao">
        <div className="cartao-topo">
          <h3>Unidades</h3>
          <a className="link-acao" href="/painel/espelho" onClick={(e) => { e.preventDefault(); ir('/painel/espelho'); }}>Abrir espelho <ArrowUpRight size={15} /></a>
        </div>
        <div className="kpis">
          <Kpi valor={c.disponivel} rotulo="Disponíveis" cor="disponivel" />
          <Kpi valor={negociacao} rotulo="Em negociação" detalhe={`${c.reservada} reservadas, ${c.proposta} propostas, ${c.contrato} em contrato`} cor="reservada" />
          <Kpi valor={c.vendida} rotulo="Vendidas" cor="vendida" />
          <Kpi valor={total} rotulo="Total de unidades" detalhe={c.bloqueada ? `${c.bloqueada} bloqueadas` : undefined} />
        </div>
        {total > 0 && (
          <>
            <div className="barra-status" role="img" aria-label="Distribuição das unidades por status">
              {STATUS.map((s) => c[s.valor] > 0 && (
                <span key={s.valor} className={`s-${s.valor}`} style={{ flexGrow: c[s.valor] }} title={`${s.plural}: ${c[s.valor]}`} />
              ))}
            </div>
            <p className="sub pequeno">
              Últimos 7 dias: {ind?.reservas_7_dias ?? 0} {ind?.reservas_7_dias === 1 ? 'reserva' : 'reservas'} e {ind?.vendas_7_dias ?? 0} {ind?.vendas_7_dias === 1 ? 'venda' : 'vendas'}.
            </p>
          </>
        )}
      </div>

      {marca.modulo_pastas && (
        <div className="cartao">
          <div className="cartao-topo">
            <h3>Pastas de compradores</h3>
            <a className="link-acao" href="/painel/pastas" onClick={(e) => { e.preventDefault(); ir('/painel/pastas'); }}>Ver pastas <ArrowUpRight size={15} /></a>
          </div>
          <div className="kpis">
            <Kpi valor={n('aguardando_analise') + n('em_analise')} rotulo="Para analisar" detalhe="Submetidas ao incorporador" cor="proposta" />
            <Kpi valor={n('pendente_correcao')} rotulo="Pendentes de correção" detalhe="Aguardando a imobiliária" cor="vendida" />
            <Kpi valor={n('aprovada')} rotulo="Documentação aprovada" cor="disponivel" />
            <Kpi valor={(ind?.pastas_total ?? 0) - (ind?.pastas_submetidas ?? 0)} rotulo="Em preparação" detalhe="Ainda não submetidas" />
          </div>
        </div>
      )}

      <div className="inicio-grade">
        <div className="cartao">
          <h3>Atalhos</h3>
          <div className="atalhos">
            <Atalho icone={<LayoutGrid size={20} />} texto="Alterar status de unidade" ao={() => ir('/painel/espelho')} />
            {marca.modulo_pastas && <Atalho icone={<FolderOpen size={20} />} texto="Analisar pastas" ao={() => ir('/painel/pastas')} />}
            {perfil.papel === 'admin' && <Atalho icone={<Building2 size={20} />} texto="Cadastrar imobiliária" ao={() => ir('/painel/imobiliarias')} />}
            <Atalho icone={<Tv size={20} />} texto="Abrir modo TV" ao={() => window.open('/tv', '_blank')} />
          </div>
        </div>
        <div className="cartao">
          <h3>Últimas movimentações</h3>
          {movs.length === 0 ? <p className="vazio">Nenhuma movimentação ainda.</p> : (
            <ol className="historico">
              {movs.map((h) => (
                <li key={h.id}>
                  <span><strong>{h.numero}</strong> {h.status_anterior ? rotuloStatus(h.status_anterior).toLowerCase() : ''} para{' '}
                    <span className={`etiqueta s-${h.status_novo}`}>{rotuloStatus(h.status_novo).toLowerCase()}</span></span>
                  <span className="quem">{h.usuario_email}, {formatarDataHora(h.criado_em)}</span>
                </li>
              ))}
            </ol>
          )}
        </div>
      </div>
    </section>
  );
}

function Kpi({ valor, rotulo, detalhe, cor }: { valor: number; rotulo: string; detalhe?: string; cor?: Status }) {
  return (
    <div className={`kpi${cor ? ` s-${cor}` : ''}`}>
      <span className="kpi-valor">{valor}</span>
      <span className="kpi-rotulo">{rotulo}</span>
      {detalhe && <span className="kpi-detalhe">{detalhe}</span>}
    </div>
  );
}

function Atalho({ icone, texto, ao }: { icone: ReactNode; texto: string; ao: () => void }) {
  return <button className="atalho" onClick={ao}>{icone}<span>{texto}</span></button>;
}
