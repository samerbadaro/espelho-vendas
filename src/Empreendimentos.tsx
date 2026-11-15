// Vários empreendimentos na mesma incorporadora: escolha do empreendimento atual,
// cadastro (administrador), acesso por imobiliária e dados comerciais de cada um.
import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { Plus } from 'lucide-react';
import { supabase } from './dados';
import { useDialogos } from './ui';

export interface EmpreendimentoItem { id: string; slug: string; sigla: string; nome: string; ativo: boolean; atual: boolean; escolhido: boolean }

const ERROS: Record<string, string> = {
  EMPREENDIMENTO_SEM_ACESSO: 'Você não tem acesso a este empreendimento.',
  ENDERECO_OU_SIGLA_EM_USO: 'Endereço ou sigla já usados por outro empreendimento.',
  SEM_PERMISSAO: 'Só o administrador pode fazer isso.',
};
const erro = (m: string) => ERROS[Object.keys(ERROS).find((k) => m.includes(k)) ?? ''] ?? 'Não foi possível concluir. Tente novamente.';

/** Empreendimentos do login e troca do atual (recarrega a página para todo o painel mudar junto). */
export function useEmpreendimentos() {
  const [lista, setLista] = useState<EmpreendimentoItem[] | null>(null);
  const carregar = useCallback(() => {
    supabase.rpc('meus_empreendimentos').then(({ data, error }) => setLista(error ? [] : (data ?? []) as EmpreendimentoItem[]));
  }, []);
  useEffect(() => { carregar(); }, [carregar]);
  const trocar = useCallback(async (id: string) => {
    const { error } = await supabase.rpc('escolher_empreendimento', { p_emp: id });
    if (error) return erro(error.message);
    window.location.reload();
    return '';
  }, []);
  return { lista, atual: lista?.find((e) => e.atual) ?? null, trocar, carregar };
}

/** Seletor no topo do menu (só aparece com mais de um empreendimento). */
export function SeletorEmpreendimento({ lista, trocar }: { lista: EmpreendimentoItem[]; trocar: (id: string) => Promise<string> }) {
  const { avisar } = useDialogos();
  if (lista.length < 2) return null;
  const atual = lista.find((e) => e.atual);
  return (
    <label className="seletor-emp">
      <span>Empreendimento</span>
      <select value={atual?.id ?? ''} onChange={async (e) => { const m = await trocar(e.target.value); if (m) avisar(m, 'erro'); }}>
        {lista.map((e) => <option key={e.id} value={e.id}>{e.sigla} · {e.nome}{e.ativo ? '' : ' (inativo)'}</option>)}
      </select>
    </label>
  );
}

/** Primeiro acesso com mais de um empreendimento: o login escolhe onde vai trabalhar. */
export function EscolhaEmpreendimento({ lista, trocar }: { lista: EmpreendimentoItem[]; trocar: (id: string) => Promise<string> }) {
  const { avisar } = useDialogos();
  return (
    <div className="escolha-emp">
      <div className="cartao escolha-emp-cartao">
        <h2>Em qual empreendimento você vai trabalhar?</h2>
        <p className="sub">Dá para trocar depois, no topo do menu.</p>
        <div className="escolha-emp-lista">
          {lista.map((e) => (
            <button key={e.id} className="escolha-emp-item" onClick={async () => { const m = await trocar(e.id); if (m) avisar(m, 'erro'); }}>
              <span className="escolha-emp-sigla">{e.sigla}</span>
              <strong>{e.nome}</strong>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------
// Administrador: empreendimentos da incorporadora e acesso das imobiliárias
// ---------------------------------------------------------------------
interface EmpBanco { id: string; slug: string; sigla: string; nome: string; ativo: boolean; ordem: number }
interface Imob { id: string; nome: string }
const slugDe = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40);

export function GestaoEmpreendimentos() {
  const { avisar } = useDialogos();
  const [emps, setEmps] = useState<EmpBanco[] | null>(null);
  const [imobs, setImobs] = useState<Imob[]>([]);
  const [bloqueios, setBloqueios] = useState<Set<string>>(new Set());
  const [edicao, setEdicao] = useState<(Omit<EmpBanco, 'id'> & { id: string | null }) | null>(null);
  const [acessos, setAcessos] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    const [e, i, b] = await Promise.all([
      supabase.from('empreendimentos').select('id, slug, sigla, nome, ativo, ordem').order('ordem').order('criado_em'),
      supabase.from('imobiliarias').select('id, nome').order('nome'),
      supabase.from('imobiliarias_bloqueios').select('imobiliaria_id, empreendimento_id'),
    ]);
    setEmps((e.data ?? []) as EmpBanco[]);
    setImobs((i.data ?? []) as Imob[]);
    setBloqueios(new Set(((b.data ?? []) as { imobiliaria_id: string; empreendimento_id: string }[]).map((x) => `${x.imobiliaria_id}|${x.empreendimento_id}`)));
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const salvar = async (ev: FormEvent) => {
    ev.preventDefault();
    if (!edicao) return;
    const { error } = await supabase.rpc('salvar_empreendimento', {
      p_id: edicao.id, p_nome: edicao.nome, p_slug: edicao.slug || slugDe(edicao.nome), p_sigla: edicao.sigla, p_ativo: edicao.ativo, p_ordem: edicao.ordem,
    });
    if (error) { avisar(erro(error.message), 'erro'); return; }
    avisar(edicao.id ? 'Empreendimento atualizado.' : 'Empreendimento criado. Troque para ele no topo do menu para configurar marca, dados comerciais e unidades.');
    setEdicao(null); carregar();
  };
  const alternarBloqueio = async (imob: string, emp: string, liberar: boolean) => {
    const { error } = await supabase.rpc('bloquear_empreendimento', { p_imobiliaria: imob, p_empreendimento: emp, p_bloquear: !liberar });
    if (error) { avisar(erro(error.message), 'erro'); return; }
    carregar();
  };

  if (!emps) return null;
  const empAcessos = emps.find((e) => e.id === acessos);
  return (
    <div className="cartao">
      <div className="cartao-topo">
        <div><h3>Empreendimentos da incorporadora</h3><p className="sub">Pastas, fila de escolha, tabela, propostas, Meeting e Portal são de cada empreendimento. Imobiliárias e logins são da incorporadora.</p></div>
        <button type="button" className="botao pequeno" onClick={() => setEdicao({ id: null, nome: '', slug: '', sigla: '', ativo: true, ordem: emps.length })}><Plus size={14} /> Novo empreendimento</button>
      </div>
      <div className="tabela-rolagem">
        <table className="tabela">
          <thead><tr><th>Sigla</th><th>Nome</th><th>Endereço</th><th>Situação</th><th>Imobiliárias com acesso</th><th /></tr></thead>
          <tbody>
            {emps.map((e) => {
              const bloqueadas = imobs.filter((i) => bloqueios.has(`${i.id}|${e.id}`)).length;
              return (
                <tr key={e.id}>
                  <td className="mono"><strong>{e.sigla}</strong></td>
                  <td>{e.nome}</td>
                  <td className="mono">{e.slug}</td>
                  <td>{e.ativo ? 'Ativo' : 'Inativo'}</td>
                  <td>{bloqueadas ? `${imobs.length - bloqueadas} de ${imobs.length}` : 'Todas'}</td>
                  <td className="nowrap">
                    <button type="button" className="botao pequeno" onClick={() => setEdicao({ ...e })}>Editar</button>{' '}
                    <button type="button" className="botao pequeno" onClick={() => setAcessos(acessos === e.id ? null : e.id)}>Acessos</button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {edicao && (
        <form className="emp-form" onSubmit={salvar}>
          <div className="grade-campos">
            <label>Nome<input value={edicao.nome} required minLength={2} onChange={(ev) => setEdicao({ ...edicao, nome: ev.target.value, slug: edicao.id ? edicao.slug : slugDe(ev.target.value) })} /></label>
            <label>Sigla (2 a 4 letras, usada nos códigos das pastas)<input value={edicao.sigla} required pattern="[A-Za-z0-9]{2,4}" maxLength={4} onChange={(ev) => setEdicao({ ...edicao, sigla: ev.target.value.toUpperCase() })} /></label>
            <label>Endereço curto<input value={edicao.slug} required pattern="[a-z0-9][a-z0-9-]{1,39}" onChange={(ev) => setEdicao({ ...edicao, slug: slugDe(ev.target.value) })} /></label>
            <label>Ordem no menu<input type="number" min={0} value={edicao.ordem} onChange={(ev) => setEdicao({ ...edicao, ordem: Number(ev.target.value) })} /></label>
          </div>
          <label className="interruptor">
            <input type="checkbox" checked={edicao.ativo} onChange={(ev) => setEdicao({ ...edicao, ativo: ev.target.checked })} />
            <span className="trilho" aria-hidden="true" />
            <span><strong>Ativo</strong><br /><span className="sub">Inativo some para imobiliárias e corretores; a equipe continua vendo.</span></span>
          </label>
          {!edicao.id && <p className="dica">O novo empreendimento nasce com as cores e os dados comerciais do primeiro, sem logo e com os módulos opcionais desligados.</p>}
          <div className="botoes-linha">
            <button type="button" className="botao pequeno" onClick={() => setEdicao(null)}>Cancelar</button>
            <button className="botao pequeno principal">{edicao.id ? 'Salvar' : 'Criar empreendimento'}</button>
          </div>
        </form>
      )}

      {empAcessos && (
        <div className="emp-acessos">
          <strong>Imobiliárias com acesso ao {empAcessos.nome}</strong>
          <p className="dica">Por padrão todas veem todos os empreendimentos. Desmarque para bloquear.</p>
          <div className="emp-acessos-lista">
            {imobs.map((i) => {
              const liberada = !bloqueios.has(`${i.id}|${empAcessos.id}`);
              return (
                <label key={i.id} className="tv-check">
                  <input type="checkbox" checked={liberada} onChange={(ev) => alternarBloqueio(i.id, empAcessos.id, ev.target.checked)} /> {i.nome}
                </label>
              );
            })}
            {!imobs.length && <span className="dica">Nenhuma imobiliária cadastrada.</span>}
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------
// Administrador: dados comerciais do empreendimento atual
// ---------------------------------------------------------------------
interface ComercialForm {
  mes_entrega: string; taxa_vp: string; comissao_pct: string; parte_sinal: string;
  alcada_automatica: boolean; alcada_auto_pv: string; alcada_vendas_pv: string;
  vendedora: string; vendedora_cnpj: string; cidade_carta: string;
}
const pct = (v: number, casas = 2) => (Math.round(v * 100 * 10 ** casas) / 10 ** casas).toLocaleString('pt-BR', { maximumFractionDigits: casas });
const ler = (s: string) => Number(s.replace(/\./g, '').replace(',', '.'));

export function DadosComerciais() {
  const { avisar } = useDialogos();
  const [f, setF] = useState<ComercialForm | null>(null);
  const [salvando, setSalvando] = useState(false);
  useEffect(() => {
    supabase.from('comercial').select('*').limit(1).maybeSingle().then(({ data }) => {
      const c = data as Record<string, unknown> | null;
      if (!c) return;
      setF({
        mes_entrega: String(c.mes_entrega).slice(0, 7), taxa_vp: pct(Number(c.taxa_vp), 3), comissao_pct: pct(Number(c.comissao_pct)),
        parte_sinal: pct(Number(c.parte_sinal), 0), alcada_automatica: !!c.alcada_automatica,
        alcada_auto_pv: String(c.alcada_auto_pv ?? 100).replace('.', ','), alcada_vendas_pv: String(c.alcada_vendas_pv ?? 98).replace('.', ','),
        vendedora: String(c.vendedora ?? ''), vendedora_cnpj: String(c.vendedora_cnpj ?? ''), cidade_carta: String(c.cidade_carta ?? ''),
      });
    });
  }, []);
  if (!f) return null;
  const muda = (k: keyof ComercialForm, v: string | boolean) => setF({ ...f, [k]: v });
  const salvar = async (ev: FormEvent) => {
    ev.preventDefault();
    const p = {
      mes_entrega: `${f.mes_entrega}-01`, taxa_vp: ler(f.taxa_vp) / 100, comissao_pct: ler(f.comissao_pct) / 100, parte_sinal: ler(f.parte_sinal) / 100,
      alcada_automatica: f.alcada_automatica, alcada_auto_pv: ler(f.alcada_auto_pv), alcada_vendas_pv: ler(f.alcada_vendas_pv),
      vendedora: f.vendedora, vendedora_cnpj: f.vendedora_cnpj, cidade_carta: f.cidade_carta,
    };
    if ([p.taxa_vp, p.comissao_pct, p.parte_sinal, p.alcada_auto_pv, p.alcada_vendas_pv].some((x) => !Number.isFinite(x))) { avisar('Confira os números.', 'erro'); return; }
    setSalvando(true);
    const { error } = await supabase.rpc('salvar_comercial', { p });
    setSalvando(false);
    if (error) { avisar('Não foi possível salvar. Confira os valores (taxa abaixo de 10% a.m., comissão abaixo de 30%).', 'erro'); return; }
    avisar('Dados comerciais salvos.');
  };
  return (
    <form className="cartao" onSubmit={salvar}>
      <h3>Dados comerciais deste empreendimento</h3>
      <p className="sub">Usados no motor da proposta (VPL, captação, comissão), nas alçadas e na carta proposta.</p>
      <div className="grade-campos">
        <label>Mês de entrega<input type="month" value={f.mes_entrega} onChange={(e) => muda('mes_entrega', e.target.value)} required /></label>
        <label>Taxa do VPL (% ao mês)<input value={f.taxa_vp} inputMode="decimal" onChange={(e) => muda('taxa_vp', e.target.value)} /></label>
        <label>Comissão (% do valor)<input value={f.comissao_pct} inputMode="decimal" onChange={(e) => muda('comissao_pct', e.target.value)} /></label>
        <label>Parte do sinal destacável para comissão (%)<input value={f.parte_sinal} inputMode="decimal" onChange={(e) => muda('parte_sinal', e.target.value)} /></label>
        <label>Aprovação automática a partir do PV de (%)<input value={f.alcada_auto_pv} inputMode="decimal" onChange={(e) => muda('alcada_auto_pv', e.target.value)} /></label>
        <label>Sec. Vendas aprova a partir do PV de (%)<input value={f.alcada_vendas_pv} inputMode="decimal" onChange={(e) => muda('alcada_vendas_pv', e.target.value)} /></label>
        <label>Vendedora (SPE)<input value={f.vendedora} onChange={(e) => muda('vendedora', e.target.value)} placeholder="Razão social da SPE" /></label>
        <label>CNPJ da vendedora<input value={f.vendedora_cnpj} onChange={(e) => muda('vendedora_cnpj', e.target.value)} placeholder="00.000.000/0000-00" /></label>
        <label>Cidade da carta proposta<input value={f.cidade_carta} onChange={(e) => muda('cidade_carta', e.target.value)} placeholder="Rio Verde" /></label>
      </div>
      <label className="interruptor">
        <input type="checkbox" checked={f.alcada_automatica} onChange={(e) => muda('alcada_automatica', e.target.checked)} />
        <span className="trilho" aria-hidden="true" />
        <span><strong>Aprovação automática</strong><br /><span className="sub">Proposta com PV acima do limite e comissão coberta é aprovada no envio.</span></span>
      </label>
      <div className="acoes"><button className="botao principal" disabled={salvando}>{salvando ? 'Salvando…' : 'Salvar dados comerciais'}</button></div>
    </form>
  );
}
