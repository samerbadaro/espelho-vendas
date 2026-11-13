// Carta proposta em A4, pronta para imprimir ou salvar em PDF pelo navegador.
// Recebe os dados já calculados; não consulta o banco.
import { Printer } from 'lucide-react';
import { Logo } from '../ui';
import { PASSO, mesDeData, type Periodicidade } from './calculo';

export interface Proponente {
  nome: string;
  cpf: string;
  rg?: string;
  orgaoEmissor?: string;
  nascimento?: string;      // AAAA-MM-DD
  nacionalidade?: string;
  estadoCivil?: string;
  regime?: string;
  profissao?: string;
  email?: string;
  celular?: string;
  endereco?: string;
  cep?: string;
}

export interface SerieCarta {
  tipo: Periodicidade;
  parcelas: number;
  primeiroVencimento: string;
  valorParcela: number;
  posChaves?: boolean;
  correcao?: string;         // "INCC até o habite-se", "Fixa"…
  formaPagamento?: string;   // "PIX", "Boleto", "Financiamento bancário"…
  observacao?: string;
}

export interface Intermediador {
  papel: string;             // "Imobiliária", "Corretor", "Coordenação"…
  nome: string;
  pct: number;               // sobre o valor da proposta
  valor: number;
  vencimento: string;
}

export interface DadosCarta {
  numero: string;
  data: string;
  local: string;
  vendedora: { nome: string; cnpj?: string };
  empreendimento: string;
  unidade: string;
  pavimento?: string;
  area?: number;
  vaga?: string;
  escaninho?: string;
  proponentes: Proponente[];
  series: SerieCarta[];
  intermediacao: Intermediador[];
  equipe: { imobiliaria?: string; corretor?: string; creci?: string; coordenador?: string };
  observacoes?: string;
  clausulas: string[];
}

const ROTULO: Record<Periodicidade, string> = {
  sinal: 'Sinal', mensal: 'Mensal', semestral: 'Semestral', anual: 'Anual', unica: 'Única',
};

const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const pct = (v: number) => (v * 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 }) + '%';
const data = (iso?: string) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : '');
const dataExtenso = (iso: string) =>
  new Date(iso.slice(0, 10) + 'T12:00:00').toLocaleDateString('pt-BR', { day: 'numeric', month: 'long', year: 'numeric' });
const ultimoVencimento = (s: SerieCarta) => {
  if (s.parcelas <= 1) return '';
  const m = mesDeData(s.primeiroVencimento) + (s.parcelas - 1) * PASSO[s.tipo];
  return `${String((m % 12) + 1).padStart(2, '0')}/${Math.floor(m / 12)}`;
};

function Campo({ rotulo, valor, largo }: { rotulo: string; valor?: string; largo?: boolean }) {
  return (
    <div className={largo ? 'cp-campo cp-largo' : 'cp-campo'}>
      <span>{rotulo}</span>
      <strong>{valor || '—'}</strong>
    </div>
  );
}

export function CartaProposta({ d }: { d: DadosCarta }) {
  const pre = d.series.filter((s) => !s.posChaves);
  const pos = d.series.filter((s) => s.posChaves);
  const soma = (l: SerieCarta[]) => l.reduce((a, s) => a + s.parcelas * s.valorParcela, 0);
  const totalPre = soma(pre);
  const totalPos = soma(pos);
  const totalInterm = d.intermediacao.reduce((a, i) => a + i.valor, 0);

  const linhas = (l: SerieCarta[]) =>
    l.map((s, i) => (
      <tr key={i}>
        <td>{ROTULO[s.tipo]}</td>
        <td className="cp-num">{s.parcelas}</td>
        <td>{data(s.primeiroVencimento)}{ultimoVencimento(s) && <small> a {ultimoVencimento(s)}</small>}</td>
        <td className="cp-num">{brl(s.valorParcela)}</td>
        <td className="cp-num">{brl(s.parcelas * s.valorParcela)}</td>
        <td>{s.correcao ?? ''}</td>
        <td>{s.formaPagamento ?? ''}{s.observacao && <small>{s.observacao}</small>}</td>
      </tr>
    ));

  return (
    <div className="cp-tela">
      <div className="cp-barra">
        <span>Carta proposta {d.numero}</span>
        <button className="botao principal" onClick={() => window.print()}>
          <Printer size={16} /> Imprimir ou salvar PDF
        </button>
      </div>

      <article className="cp-folha">
        <header className="cp-topo">
          <Logo escuro className="cp-logo" />
          <div>
            <h1>Carta proposta</h1>
            <p>N.º {d.numero} · {data(d.data)}</p>
          </div>
        </header>

        <p className="cp-intro">
          À <strong>{d.vendedora.nome}</strong>{d.vendedora.cnpj && <> (CNPJ {d.vendedora.cnpj})</>}. Por meio
          desta, o(s) proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição da unidade descrita,
          nos termos e condições a seguir, para avaliação da vendedora.
        </p>

        <section>
          <h2>Imóvel</h2>
          <div className="cp-grade">
            <Campo rotulo="Empreendimento" valor={d.empreendimento} largo />
            <Campo rotulo="Unidade" valor={d.unidade} />
            <Campo rotulo="Pavimento" valor={d.pavimento} />
            <Campo rotulo="Área privativa" valor={d.area ? `${d.area.toLocaleString('pt-BR')} m²` : ''} />
            <Campo rotulo="Vaga" valor={d.vaga || 'Não inclui'} />
            <Campo rotulo="Escaninho" valor={d.escaninho || 'Não inclui'} />
            <Campo rotulo="Valor da proposta" valor={brl(totalPre + totalPos)} />
          </div>
        </section>

        {d.proponentes.map((p, i) => (
          <section key={i} className="cp-bloco">
            <h2>{d.proponentes.length > 1 ? `Proponente ${i + 1}` : 'Proponente'}</h2>
            <div className="cp-grade">
              <Campo rotulo="Nome" valor={p.nome} largo />
              <Campo rotulo="CPF" valor={p.cpf} />
              <Campo rotulo="RG / órgão emissor" valor={[p.rg, p.orgaoEmissor].filter(Boolean).join(' / ')} />
              <Campo rotulo="Nascimento" valor={data(p.nascimento)} />
              <Campo rotulo="Nacionalidade" valor={p.nacionalidade} />
              <Campo rotulo="Estado civil" valor={[p.estadoCivil, p.regime].filter(Boolean).join(' · ')} />
              <Campo rotulo="Profissão" valor={p.profissao} />
              <Campo rotulo="Celular" valor={p.celular} />
              <Campo rotulo="E-mail" valor={p.email} />
              <Campo rotulo="Endereço" valor={[p.endereco, p.cep && `CEP ${p.cep}`].filter(Boolean).join(' · ')} largo />
            </div>
          </section>
        ))}

        <section className="cp-bloco">
          <h2>Preço e forma de pagamento</h2>
          <table className="cp-tabela">
            <thead>
              <tr>
                <th>Série</th><th className="cp-num">Parc.</th><th>Vencimentos</th>
                <th className="cp-num">Valor da parcela</th><th className="cp-num">Total da série</th>
                <th>Correção</th><th>Pagamento</th>
              </tr>
            </thead>
            <tbody>{linhas(pre)}</tbody>
            <tbody>
              <tr className="cp-subtotal"><td colSpan={4}>Total até as chaves</td><td className="cp-num">{brl(totalPre)}</td><td colSpan={2} /></tr>
            </tbody>
            {pos.length > 0 && (
              <>
                <tbody>{linhas(pos)}</tbody>
                <tbody>
                  <tr className="cp-subtotal"><td colSpan={4}>Total pós-chaves / financiamento</td><td className="cp-num">{brl(totalPos)}</td><td colSpan={2} /></tr>
                </tbody>
              </>
            )}
            <tfoot>
              <tr><td colSpan={4}>Total da proposta nesta data</td><td className="cp-num">{brl(totalPre + totalPos)}</td><td colSpan={2} /></tr>
            </tfoot>
          </table>
        </section>

        {d.intermediacao.length > 0 && (
          <section className="cp-bloco">
            <h2>Intermediação imobiliária</h2>
            <p className="cp-nota">Paga com o sinal de negócio e destacada do valor da proposta.</p>
            <table className="cp-tabela">
              <thead>
                <tr><th>Intermediador</th><th>Função</th><th className="cp-num">%</th><th className="cp-num">Valor</th><th>Vencimento</th></tr>
              </thead>
              <tbody>
                {d.intermediacao.map((x, i) => (
                  <tr key={i}>
                    <td>{x.nome}</td><td>{x.papel}</td><td className="cp-num">{pct(x.pct)}</td>
                    <td className="cp-num">{brl(x.valor)}</td><td>{data(x.vencimento)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr><td colSpan={3}>Total da intermediação</td><td className="cp-num">{brl(totalInterm)}</td><td /></tr>
              </tfoot>
            </table>
            <div className="cp-grade cp-equipe">
              <Campo rotulo="Imobiliária" valor={d.equipe.imobiliaria} />
              <Campo rotulo="Corretor" valor={[d.equipe.corretor, d.equipe.creci && `CRECI ${d.equipe.creci}`].filter(Boolean).join(' · ')} />
              <Campo rotulo="Coordenação comercial" valor={d.equipe.coordenador} />
            </div>
          </section>
        )}

        {d.observacoes && (
          <section className="cp-bloco">
            <h2>Observações</h2>
            <p className="cp-obs">{d.observacoes}</p>
          </section>
        )}

        <section className="cp-bloco cp-clausulas">
          <h2>Condições gerais</h2>
          <ol>{d.clausulas.map((c, i) => <li key={i}>{c}</li>)}</ol>
        </section>

        <section className="cp-assinaturas">
          <p>{d.local}, {dataExtenso(d.data)}.</p>
          <div className="cp-linhas">
            {d.proponentes.map((p, i) => (
              <div key={i}><span />{p.nome}<small>Proponente · CPF {p.cpf}</small></div>
            ))}
            <div><span />{d.equipe.corretor || 'Corretor'}<small>Corretor{d.equipe.imobiliaria ? ` · ${d.equipe.imobiliaria}` : ''}</small></div>
          </div>
          <div className="cp-aceite">
            <strong>Aceite da vendedora</strong>
            <div className="cp-linhas">
              <div><span />{d.vendedora.nome}<small>Data: ____/____/______</small></div>
            </div>
          </div>
        </section>
      </article>
    </div>
  );
}
