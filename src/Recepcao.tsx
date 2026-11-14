import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { Check, FileText, RotateCcw, Search, UserPlus, X } from 'lucide-react';
import { supabase } from './dados';
import { formatarTelefone } from './util';
import { useDialogos } from './ui';

interface Evento { id: string; nome: string; data_hora: string | null }
interface Participante {
  id: string; evento_id: string; nome: string; imobiliaria: string | null; telefone: string | null;
  presente: boolean; chegada_em: string | null; incluido_na_hora: boolean;
}

/** Busca sem acento e sem diferença de maiúsculas. */
const chave = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const hora = (iso: string | null) => (iso ? new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : '');

export function Recepcao() {
  const { avisar } = useDialogos();
  const [eventos, setEventos] = useState<Evento[] | null>(null);
  const [eventoId, setEventoId] = useState('');
  const [lista, setLista] = useState<Participante[]>([]);
  const [busca, setBusca] = useState('');
  const [aba, setAba] = useState<'aguardando' | 'confirmados'>('aguardando');
  const [incluindo, setIncluindo] = useState(false);
  const [ocupado, setOcupado] = useState<string | null>(null);
  const campo = useRef<HTMLInputElement>(null);

  useEffect(() => {
    supabase.from('recepcao_eventos').select('id, nome, data_hora').order('data_hora', { ascending: false })
      .then(({ data }) => {
        const l = (data as Evento[]) ?? [];
        setEventos(l);
        if (l.length) setEventoId(l[0].id);
      });
  }, []);

  const carregar = useCallback(async () => {
    if (!eventoId) return;
    const { data, error } = await supabase.from('recepcao_participantes')
      .select('id, evento_id, nome, imobiliaria, telefone, presente, chegada_em, incluido_na_hora')
      .eq('evento_id', eventoId).order('nome').limit(5000);
    if (error) { avisar('Não foi possível carregar a lista.', 'erro'); return; }
    setLista((data as Participante[]) ?? []);
  }, [eventoId, avisar]);
  useEffect(() => { carregar(); }, [carregar]);

  // outras pessoas na recepção confirmando ao mesmo tempo
  useEffect(() => {
    if (!eventoId) return;
    const canal = supabase.channel(`recepcao-${eventoId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'recepcao_participantes', filter: `evento_id=eq.${eventoId}` }, () => carregar())
      .subscribe();
    return () => { supabase.removeChannel(canal); };
  }, [eventoId, carregar]);

  const termo = chave(busca.trim());
  const digitos = busca.replace(/\D/g, '');
  const bate = (p: Participante) => !termo
    || chave(p.nome).includes(termo)
    || chave(p.imobiliaria ?? '').includes(termo)
    || (digitos.length >= 4 && (p.telefone ?? '').includes(digitos));

  const aguardando = useMemo(() => lista.filter((p) => !p.presente && bate(p)), [lista, termo, digitos]); // eslint-disable-line react-hooks/exhaustive-deps
  const confirmados = useMemo(() => lista.filter((p) => p.presente && bate(p))
    .sort((a, b) => (b.chegada_em ?? '').localeCompare(a.chegada_em ?? '')), [lista, termo, digitos]); // eslint-disable-line react-hooks/exhaustive-deps
  const totalPresentes = lista.filter((p) => p.presente).length;

  const marcar = async (p: Participante, presente: boolean) => {
    setOcupado(p.id);
    // atualiza na hora; o banco confirma em seguida
    setLista((l) => l.map((x) => (x.id === p.id ? { ...x, presente, chegada_em: presente ? new Date().toISOString() : null } : x)));
    const { error } = await supabase.rpc('marcar_presenca', { p_id: p.id, p_presente: presente });
    setOcupado(null);
    if (error) { avisar('Não foi possível salvar. Tente de novo.', 'erro'); carregar(); return; }
    if (presente) {
      avisar(`${p.nome} confirmado(a).`);
      setBusca('');
      campo.current?.focus();
    } else {
      avisar(`${p.nome} voltou para a lista.`);
    }
  };

  const [gerando, setGerando] = useState(false);

  /** PDF da lista de presença: resumo por imobiliária e presentes agrupados por imobiliária. */
  const baixarPdf = async () => {
    const ev = eventos?.find((e) => e.id === eventoId);
    if (!ev) return;
    setGerando(true);
    try {
      const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
      const doc = new jsPDF({ unit: 'mm', format: 'a4' });
      const L = doc.internal.pageSize.getWidth();
      const M = 14;
      const escuro: [number, number, number] = [29, 30, 25];
      const cinza: [number, number, number] = [110, 104, 98];
      const destaque: [number, number, number] = [240, 127, 64];
      const semImob = 'Sem imobiliária';
      const presentes = lista.filter((p) => p.presente);
      const incluidos = presentes.filter((p) => p.incluido_na_hora).length;
      const totalConvidados = lista.filter((p) => !p.incluido_na_hora).length;
      const presentesDaLista = presentes.length - incluidos;
      const taxa = totalConvidados ? Math.round((presentesDaLista / totalConvidados) * 100) : 0;

      // ---------- cabeçalho
      doc.setFillColor(...destaque); doc.rect(M, 14, 3, 16, 'F');
      doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(...escuro);
      doc.text('Lista de presença', M + 7, 21);
      doc.setFont('helvetica', 'normal'); doc.setFontSize(11); doc.setTextColor(...cinza);
      const quando = ev.data_hora ? new Date(ev.data_hora).toLocaleString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
      doc.text([ev.nome, quando].filter(Boolean).join('  ·  '), M + 7, 28);
      doc.setFontSize(9);
      doc.text(`Gerado em ${new Date().toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}`, L - M, 21, { align: 'right' });

      // ---------- números do evento
      const caixas: [string, string][] = [
        [String(presentes.length), 'presentes'],
        [String(totalConvidados), 'convidados na lista'],
        [`${taxa}%`, 'da lista compareceu'],
        [String(incluidos), 'incluídos na hora'],
      ];
      const larg = (L - 2 * M - 3 * 4) / 4;
      caixas.forEach(([n, r], k) => {
        const x = M + k * (larg + 4);
        doc.setFillColor(244, 241, 238); doc.setDrawColor(218, 211, 204);
        doc.roundedRect(x, 36, larg, 20, 2, 2, 'FD');
        doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(...escuro);
        doc.text(n, x + 5, 46);
        doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...cinza);
        doc.text(r, x + 5, 52);
      });

      // ---------- resumo por imobiliária
      const grupos = new Map<string, { convidados: number; presentes: Participante[] }>();
      lista.forEach((p) => {
        const k = p.imobiliaria?.trim() || semImob;
        const g = grupos.get(k) ?? { convidados: 0, presentes: [] };
        if (!p.incluido_na_hora) g.convidados++;
        if (p.presente) g.presentes.push(p);
        grupos.set(k, g);
      });
      const ordem = [...grupos.entries()].sort((a, b) => b[1].presentes.length - a[1].presentes.length || a[0].localeCompare(b[0], 'pt-BR'));

      doc.setFont('helvetica', 'bold'); doc.setFontSize(12); doc.setTextColor(...escuro);
      doc.text('Presença por imobiliária', M, 66);
      autoTable(doc, {
        startY: 69,
        head: [['Imobiliária', 'Convidados', 'Presentes', 'Comparecimento']],
        body: ordem.map(([nome, g]) => [nome, String(g.convidados), String(g.presentes.length), g.convidados ? `${Math.round((g.presentes.filter((p) => !p.incluido_na_hora).length / g.convidados) * 100)}%` : '—']),
        foot: [['Total', String(totalConvidados), String(presentes.length), `${taxa}%`]],
        styles: { font: 'helvetica', fontSize: 9, cellPadding: 2, lineColor: [225, 220, 214], lineWidth: 0.1 },
        headStyles: { fillColor: escuro, textColor: 255, fontStyle: 'bold' },
        footStyles: { fillColor: [244, 241, 238], textColor: escuro, fontStyle: 'bold' },
        columnStyles: { 1: { halign: 'right', cellWidth: 28 }, 2: { halign: 'right', cellWidth: 28 }, 3: { halign: 'right', cellWidth: 34 } },
        alternateRowStyles: { fillColor: [250, 249, 247] },
        didParseCell: (d) => { if (d.column.index > 0) d.cell.styles.halign = 'right'; },
        margin: { left: M, right: M, bottom: 16 },
      });

      // ---------- presentes, agrupados por imobiliária (ordem alfabética)
      doc.addPage();
      doc.setFont('helvetica', 'bold'); doc.setFontSize(14); doc.setTextColor(...escuro);
      doc.text('Presentes', M, 20);
      doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(...cinza);
      doc.text('Por imobiliária, em ordem alfabética, com o horário de chegada.', M, 26);

      type Linha = { tipo: 'grupo'; nome: string; qtd: number } | { tipo: 'pessoa'; p: Participante; n: number };
      const linhas: Linha[] = [];
      let n = 0;
      [...grupos.entries()].filter(([, g]) => g.presentes.length)
        .sort((a, b) => (a[0] === semImob ? 1 : b[0] === semImob ? -1 : a[0].localeCompare(b[0], 'pt-BR')))
        .forEach(([nome, g]) => {
          linhas.push({ tipo: 'grupo', nome, qtd: g.presentes.length });
          [...g.presentes].sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR')).forEach((p) => linhas.push({ tipo: 'pessoa', p, n: ++n }));
        });

      autoTable(doc, {
        startY: 30,
        head: [['#', 'Nome', 'Chegada', 'Observação']],
        body: linhas.map((l) => l.tipo === 'grupo'
          ? [{ content: `${l.nome}  ·  ${l.qtd} ${l.qtd === 1 ? 'presente' : 'presentes'}`, colSpan: 4 }]
          : [String(l.n), l.p.nome, hora(l.p.chegada_em), l.p.incluido_na_hora ? 'Incluído na hora' : '']),
        styles: { font: 'helvetica', fontSize: 9.5, cellPadding: 2.2, lineColor: [225, 220, 214], lineWidth: 0.1, valign: 'middle' },
        headStyles: { fillColor: escuro, textColor: 255, fontStyle: 'bold' },
        columnStyles: { 0: { cellWidth: 11, halign: 'right', textColor: cinza }, 2: { cellWidth: 22, halign: 'center' }, 3: { cellWidth: 38, textColor: cinza } },
        didParseCell: (d) => {
          if (d.section === 'head') { if (d.column.index === 0) d.cell.styles.halign = 'right'; if (d.column.index === 2) d.cell.styles.halign = 'center'; return; }
          if (d.section !== 'body') return;
          const l = linhas[d.row.index];
          if (l.tipo === 'grupo') {
            d.cell.styles.fillColor = [240, 233, 226];
            d.cell.styles.fontStyle = 'bold';
            d.cell.styles.textColor = escuro;
            d.cell.styles.fontSize = 10;
            d.cell.styles.halign = 'left';
          }
        },
        showHead: 'everyPage',
        margin: { left: M, right: M, top: 18, bottom: 16 },
      });

      // ---------- rodapé com paginação
      const total = doc.getNumberOfPages();
      for (let pg = 1; pg <= total; pg++) {
        doc.setPage(pg);
        const A = doc.internal.pageSize.getHeight();
        doc.setDrawColor(225, 220, 214); doc.line(M, A - 11, L - M, A - 11);
        doc.setFontSize(8); doc.setTextColor(...cinza);
        doc.text(ev.nome, M, A - 6);
        doc.text(`Página ${pg} de ${total}`, L - M, A - 6, { align: 'right' });
      }

      doc.save(`lista-de-presenca-${chave(ev.nome).replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}.pdf`);
    } catch {
      avisar('Não foi possível gerar o PDF.', 'erro');
    } finally {
      setGerando(false);
    }
  };

  if (eventos == null) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  if (!eventos.length) return <section className="secao"><h2>Recepção</h2><p className="vazio">Nenhum evento com lista de convidados.</p></section>;
  const evento = eventos.find((e) => e.id === eventoId);
  const pct = lista.length ? Math.round((totalPresentes / lista.length) * 100) : 0;

  return (
    <section className="secao recepcao">
      <div className="secao-topo">
        <div>
          <h2>Recepção</h2>
          {eventos.length > 1 ? (
            <select className="seletor-evento" value={eventoId} onChange={(e) => setEventoId(e.target.value)} aria-label="Evento">
              {eventos.map((e) => <option key={e.id} value={e.id}>{e.nome}</option>)}
            </select>
          ) : (
            <p className="sub">{evento?.nome}{evento?.data_hora ? `, ${new Date(evento.data_hora).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}` : ''}</p>
          )}
        </div>
        <div className="acoes-topo">
          <button className="botao" onClick={() => setIncluindo(true)}><UserPlus size={16} /> Incluir pessoa</button>
          <button className="botao" onClick={baixarPdf} disabled={!totalPresentes || gerando}><FileText size={16} /> {gerando ? 'Gerando…' : 'Lista de presença (PDF)'}</button>
        </div>
      </div>

      <div className="cartao placar">
        <div><strong>{totalPresentes}</strong><span>presentes</span></div>
        <div><strong>{lista.length - totalPresentes}</strong><span>aguardando</span></div>
        <div className="placar-barra" aria-label={`${pct}% presentes`}><span style={{ width: `${pct}%` }} /></div>
      </div>

      <label className="busca-recepcao">
        <Search size={20} aria-hidden="true" />
        <input ref={campo} value={busca} onChange={(e) => setBusca(e.target.value)} autoFocus
          placeholder="Buscar por nome, imobiliária ou telefone" aria-label="Buscar convidado" />
        {busca && <button className="icone-botao" onClick={() => { setBusca(''); campo.current?.focus(); }} aria-label="Limpar busca"><X size={18} /></button>}
      </label>

      <div className="abas-recepcao" role="tablist">
        <button role="tab" aria-selected={aba === 'aguardando'} className={aba === 'aguardando' ? 'ativa' : ''} onClick={() => setAba('aguardando')}>
          Aguardando <span>{aguardando.length}</span>
        </button>
        <button role="tab" aria-selected={aba === 'confirmados'} className={aba === 'confirmados' ? 'ativa' : ''} onClick={() => setAba('confirmados')}>
          Confirmados <span>{confirmados.length}</span>
        </button>
      </div>

      <div className="colunas-recepcao">
        <div className={`coluna-recepcao${aba === 'aguardando' ? ' visivel' : ''}`}>
          <h3>Aguardando <span>{aguardando.length}</span></h3>
          {aguardando.length === 0 ? (
            <p className="vazio">{termo ? 'Ninguém na lista com essa busca. Confira em "Confirmados" ou use "Incluir pessoa".' : 'Todos os convidados já chegaram.'}</p>
          ) : (
            <ul className="lista-recepcao">
              {aguardando.slice(0, 300).map((p) => (
                <li key={p.id}>
                  <div className="pessoa">
                    <strong>{p.nome}</strong>
                    <span>{[p.imobiliaria, formatarTelefone(p.telefone)].filter(Boolean).join(' · ')}</span>
                  </div>
                  <button className="botao-check" onClick={() => marcar(p, true)} disabled={ocupado === p.id} aria-label={`Confirmar chegada de ${p.nome}`}>
                    <Check size={20} /> <span>Confirmar</span>
                  </button>
                </li>
              ))}
              {aguardando.length > 300 && <li className="mais">Mais {aguardando.length - 300} nomes. Use a busca.</li>}
            </ul>
          )}
        </div>

        <div className={`coluna-recepcao confirmados${aba === 'confirmados' ? ' visivel' : ''}`}>
          <h3>Confirmados <span>{confirmados.length}</span></h3>
          {confirmados.length === 0 ? <p className="vazio">{termo ? 'Ninguém confirmado com essa busca.' : 'Ninguém confirmado ainda.'}</p> : (
            <ul className="lista-recepcao">
              {confirmados.map((p) => (
                <li key={p.id}>
                  <div className="pessoa">
                    <strong>{p.nome}</strong>
                    <span>{[p.imobiliaria, `chegou às ${hora(p.chegada_em)}`, p.incluido_na_hora ? 'incluído na hora' : ''].filter(Boolean).join(' · ')}</span>
                  </div>
                  <button className="botao pequeno" onClick={() => marcar(p, false)} disabled={ocupado === p.id} aria-label={`Desfazer confirmação de ${p.nome}`}>
                    <RotateCcw size={14} /> Desfazer
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      {incluindo && <IncluirPessoa eventoId={eventoId} nomeInicial={busca} aoFechar={() => setIncluindo(false)}
        aoSalvar={(nome) => { setIncluindo(false); setBusca(''); avisar(`${nome} incluído(a) e confirmado(a).`); carregar(); }} />}
    </section>
  );
}

function IncluirPessoa({ eventoId, nomeInicial, aoFechar, aoSalvar }: { eventoId: string; nomeInicial: string; aoFechar: () => void; aoSalvar: (nome: string) => void }) {
  const [nome, setNome] = useState(/\d/.test(nomeInicial) ? '' : nomeInicial);
  const [imob, setImob] = useState('');
  const [tel, setTel] = useState('');
  const [erro, setErro] = useState('');

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);

  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    if (nome.trim().length < 3) { setErro('Informe o nome.'); return; }
    const { error } = await supabase.rpc('incluir_participante', { p_evento: eventoId, p_nome: nome, p_imobiliaria: imob, p_telefone: tel });
    if (error) { setErro('Não foi possível incluir. Tente de novo.'); return; }
    aoSalvar(nome.trim());
  };

  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="inc-titulo" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="inc-titulo">Incluir pessoa que não está na lista</h2>
        <p className="sub">Ela entra direto como confirmada.</p>
        <div className="campos">
          <label className="largo">Nome completo<input value={nome} onChange={(e) => setNome(e.target.value)} autoFocus maxLength={120} /></label>
          <label>Imobiliária<input value={imob} onChange={(e) => setImob(e.target.value)} maxLength={80} /></label>
          <label>Telefone<input value={formatarTelefone(tel)} onChange={(e) => setTel(e.target.value.replace(/\D/g, '').slice(0, 11))} inputMode="tel" /></label>
        </div>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal">Incluir e confirmar</button>
        </div>
      </form>
    </div>
  );
}
