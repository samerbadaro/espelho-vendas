// Aba "Dados para contrato" da pasta: só administrador e Sec. Vendas, depois da proposta aprovada.
import { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, CheckCircle2, Info, Sparkles } from 'lucide-react';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { CAMPOS_ENDERECO, CAMPOS_PESSOA, lerDocumentosComIA, MODELO_IA, padronizar, type Alerta, type DadosContrato as Dados, type Pessoa } from './leitura';

interface Registro {
  dados: Dados; fontes: Record<string, string>; alertas: Alerta[]; status: 'rascunho' | 'conferido';
  lido_em: string | null; lido_por: string | null; conferido_em: string | null; conferido_por: string | null;
}

export function DadosContrato({ pastaId, temConjuge, aoMudar }: { pastaId: string; temConjuge: boolean; aoMudar: () => void }) {
  const { avisar, confirmar } = useDialogos();
  const [liberado, setLiberado] = useState<boolean | null>(null);
  const [reg, setReg] = useState<Registro | null>(null);
  const [dados, setDados] = useState<Dados>({});
  const [lendo, setLendo] = useState('');
  const [salvando, setSalvando] = useState(false);
  const [alterado, setAlterado] = useState(false);

  const carregar = useCallback(async () => {
    const { data: ok } = await supabase.rpc('contrato_liberado', { p_pasta: pastaId });
    setLiberado(!!ok);
    if (!ok) return;
    const { data } = await supabase.from('dados_contrato').select('*').eq('pasta_id', pastaId).maybeSingle();
    setReg((data as Registro) ?? null);
    setDados(padronizar((data as Registro)?.dados ?? {}));
    setAlterado(false);
  }, [pastaId]);
  useEffect(() => { carregar(); }, [carregar]);

  if (!liberado) return null;

  const ler = async () => {
    if (reg && !(await confirmar({ titulo: 'Ler os documentos de novo?', texto: 'Os campos serão substituídos pela nova leitura, inclusive o que foi corrigido à mão, e a conferência volta para pendente.', confirmar: 'Ler de novo' }))) return;
    try {
      const r = await lerDocumentosComIA(pastaId, setLendo);
      setLendo('Gravando…');
      const { error } = await supabase.rpc('gravar_leitura_ia', {
        p_pasta: pastaId, p_dados: r.dados, p_fontes: r.fontes, p_alertas: r.alertas, p_modelo: MODELO_IA,
        p_documentos: r.lidos, p_tokens_entrada: r.tokensEntrada, p_tokens_saida: r.tokensSaida,
      });
      if (error) throw new Error('Não foi possível gravar a leitura.');
      avisar(`${r.lidos} documento(s) lido(s). Confira os campos e os alertas.`);
      await carregar(); aoMudar();
    } catch (e) {
      avisar((e as Error).message, 'erro');
    } finally { setLendo(''); }
  };

  const salvar = async (conferido: boolean) => {
    setSalvando(true);
    const { error } = await supabase.rpc('salvar_dados_contrato', { p_pasta: pastaId, p_dados: padronizar(dados), p_conferido: conferido });
    setSalvando(false);
    if (error) { avisar('Não foi possível salvar.', 'erro'); return; }
    avisar(conferido ? 'Dados conferidos. Prontos para o contrato.' : 'Alterações salvas.');
    await carregar(); aoMudar();
  };

  const mudar = (quem: 'comprador' | 'conjuge', campo: string, valor: string, endereco = false) => {
    setAlterado(true);
    setDados((d) => {
      const p: Pessoa = { ...(d[quem] ?? {}) };
      if (endereco) p.endereco = { ...(p.endereco ?? {}), [campo]: valor };
      else (p as Record<string, string>)[campo] = valor;
      return { ...d, [quem]: p };
    });
  };

  const alertas = reg?.alertas ?? [];
  const pessoas: ('comprador' | 'conjuge')[] = temConjuge ? ['comprador', 'conjuge'] : ['comprador'];

  return (
    <div className="cartao dados-contrato">
      <div className="cartao-topo">
        <div>
          <h3>Dados para contrato</h3>
          <p className="sub">
            {!reg ? 'A IA lê os documentos da pasta e preenche os campos. Depois a equipe confere.'
              : reg.status === 'conferido' ? <>Conferido por {reg.conferido_por} em {formatarDataHora(reg.conferido_em!)}</>
              : <>Lido com IA por {reg.lido_por ?? '—'} em {reg.lido_em ? formatarDataHora(reg.lido_em) : '—'}. Pendente de conferência.</>}
          </p>
        </div>
        {reg && <span className={`selo ${reg.status === 'conferido' ? 'sp-aprovada' : 'sp-aguardando_analise'}`}>{reg.status === 'conferido' ? 'Conferido' : 'A conferir'}</span>}
      </div>

      <div className="dc-acoes">
        <button className="botao principal" onClick={ler} disabled={!!lendo}><Sparkles size={16} /> {lendo || (reg ? 'Ler de novo com IA' : 'Ler documentos com IA')}</button>
      </div>

      {alertas.length > 0 && (
        <ul className="dc-alertas">
          {alertas.map((a, i) => (
            <li key={i} className={a.nivel}>{a.nivel === 'atencao' ? <AlertTriangle size={16} /> : <Info size={16} />}<span>{a.texto}</span></li>
          ))}
        </ul>
      )}

      {(reg || alterado) && pessoas.map((quem) => {
        const p = dados[quem] ?? {};
        const fonte = (c: string) => reg?.fontes?.[`${quem}.${c}`];
        return (
          <fieldset key={quem} className="dc-pessoa">
            <legend>{quem === 'comprador' ? 'Comprador' : 'Cônjuge'}</legend>
            <div className="dc-grade">
              {CAMPOS_PESSOA.map(([k, rot]) => (
                <label key={k} className={k === 'nome' ? 'dc-largo' : ''}>
                  <span>{rot}{fonte(k) && <small className="dc-fonte" >{fonte(k)}</small>}</span>
                  <input value={(p as Record<string, string>)[k] ?? ''} onChange={(e) => mudar(quem, k, e.target.value)} />
                </label>
              ))}
              {CAMPOS_ENDERECO.map(([k, rot]) => (
                <label key={k} className={k === 'logradouro' ? 'dc-largo' : ''}>
                  <span>{rot}{fonte(`endereco.${k}`) && <small className="dc-fonte">{fonte(`endereco.${k}`)}</small>}</span>
                  <input value={p.endereco?.[k] ?? ''} onChange={(e) => mudar(quem, k, e.target.value, true)} />
                </label>
              ))}
            </div>
          </fieldset>
        );
      })}

      {reg && (
        <div className="acoes">
          <p className="sub dc-dica">Ao lado de cada campo aparece o documento de onde a IA tirou a informação.</p>
          <button className="botao" onClick={() => salvar(false)} disabled={salvando || !alterado}>Salvar alterações</button>
          <button className="botao principal" onClick={() => salvar(true)} disabled={salvando}><CheckCircle2 size={16} /> Marcar como conferido</button>
        </div>
      )}
    </div>
  );
}
