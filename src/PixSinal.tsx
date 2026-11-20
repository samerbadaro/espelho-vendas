// Pix do sinal: configuração (administrador) e cartão na pasta (modo "Pix gerado pelo sistema").
import { useCallback, useEffect, useState } from 'react';
import { CheckCircle2, Copy, Download, QrCode, RefreshCw } from 'lucide-react';
import { supabase, formatarDataHora } from './dados';
import { useDialogos } from './ui';
import { formatarCNPJ, formatarCPF } from './util';

export interface ConfigPix { pix_modo: 'comprovante' | 'integrado'; pix_valor: number; pix_validade_horas: number; pix_provedor: 'simulado' | 'itau' | 'infinitepay' | 'mercadopago' }
interface Cobranca {
  id: string; valor: number; provedor: string; txid: string; copia_cola: string; status: 'pendente' | 'pago' | 'cancelado';
  expira_em: string; pago_em: string | null; pagador_nome: string | null; pagador_documento: string | null; e2e_id: string | null; criado_em: string;
}
const PROVEDORES: { v: ConfigPix['pix_provedor']; r: string; pronto: boolean }[] = [
  { v: 'simulado', r: 'Simulado (testes na homologação)', pronto: true },
  { v: 'itau', r: 'Itaú — API Pix (aguardando credenciais)', pronto: false },
  { v: 'infinitepay', r: 'InfinitePay (aguardando credenciais)', pronto: false },
  { v: 'mercadopago', r: 'Mercado Pago (aguardando credenciais)', pronto: false },
];
const real = (v: number) => Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

export function useConfigPix() {
  const [c, setC] = useState<ConfigPix | null>(null);
  const carregar = useCallback(async () => {
    const { data } = await supabase.from('config').select('pix_modo, pix_valor, pix_validade_horas, pix_provedor').eq('id', 1).maybeSingle();
    setC((data as ConfigPix) ?? null);
  }, []);
  useEffect(() => { carregar(); }, [carregar]);
  return { config: c, recarregar: carregar };
}

/** Cartão no Empreendimento (somente administrador). */
export function ConfigPixSinal() {
  const { avisar } = useDialogos();
  const { config, recarregar } = useConfigPix();
  const [f, setF] = useState<ConfigPix | null>(null);
  useEffect(() => { if (config && !f) setF(config); }, [config, f]);
  if (!f) return null;
  const salvar = async () => {
    if (!(f.pix_valor > 0)) { avisar('Informe o valor do Pix.', 'erro'); return; }
    const { error } = await supabase.from('config').update({ pix_modo: f.pix_modo, pix_valor: f.pix_valor, pix_validade_horas: f.pix_validade_horas, pix_provedor: f.pix_provedor }).eq('id', 1);
    if (error) avisar('Não foi possível salvar.', 'erro'); else { avisar('Configuração do Pix salva.'); recarregar(); }
  };
  return (
    <div className="cartao">
      <div className="cartao-topo"><div><h3>Sinal via Pix na pasta</h3><p className="sub">Como o comprovante do sinal entra na pasta.</p></div></div>
      <div className="pix-modos">
        <label className={`pix-modo ${f.pix_modo === 'comprovante' ? 'ativo' : ''}`}>
          <input type="radio" checked={f.pix_modo === 'comprovante'} onChange={() => setF({ ...f, pix_modo: 'comprovante' })} />
          <span><strong>Comprovante anexado</strong><br /><span className="sub">O corretor anexa o comprovante do PIX, como hoje.</span></span>
        </label>
        <label className={`pix-modo ${f.pix_modo === 'integrado' ? 'ativo' : ''}`}>
          <input type="radio" checked={f.pix_modo === 'integrado'} onChange={() => setF({ ...f, pix_modo: 'integrado' })} />
          <span><strong>Pix gerado pelo sistema</strong><br /><span className="sub">A pasta gera um Pix de valor fixo; quando o cliente paga, a baixa e o comprovante entram sozinhos. O anexo deixa de ser exigido.</span></span>
        </label>
      </div>
      {f.pix_modo === 'integrado' && (
        <div className="grade-campos pix-campos">
          <label>Valor do Pix (R$)<input inputMode="decimal" value={String(f.pix_valor).replace('.', ',')} onChange={(e) => setF({ ...f, pix_valor: Number(e.target.value.replace(/\./g, '').replace(',', '.')) || 0 })} /></label>
          <label>Validade (horas)<input type="number" min={1} max={720} value={f.pix_validade_horas} onChange={(e) => setF({ ...f, pix_validade_horas: Number(e.target.value) || 48 })} /></label>
          <label className="largo">Banco / provedor
            <select value={f.pix_provedor} onChange={(e) => setF({ ...f, pix_provedor: e.target.value as ConfigPix['pix_provedor'] })}>
              {PROVEDORES.map((p) => <option key={p.v} value={p.v} disabled={!p.pronto}>{p.r}</option>)}
            </select>
          </label>
        </div>
      )}
      <div className="acoes"><button type="button" className="botao principal" onClick={salvar}>Salvar configuração do Pix</button></div>
    </div>
  );
}

async function baixarComprovante(c: Cobranca, codigoPasta: string) {
  const { jsPDF } = await import('jspdf');
  const doc = new jsPDF({ unit: 'mm', format: 'a5' });
  const doc_ = (d: string | null) => { const s = (d ?? '').replace(/\D/g, ''); return s.length === 14 ? formatarCNPJ(s) : s.length === 11 ? formatarCPF(s) : d ?? ''; };
  doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.text('Comprovante de pagamento — Pix do sinal', 12, 18);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
  const linhas: [string, string][] = [
    ['Pasta', codigoPasta], ['Valor', real(c.valor)], ['Pago em', c.pago_em ? formatarDataHora(c.pago_em) : '—'],
    ['Pagador', c.pagador_nome ?? '—'], ['CPF/CNPJ do pagador', doc_(c.pagador_documento)], ['Identificador (txid)', c.txid],
    ['Código da transação (E2E)', c.e2e_id ?? '—'], ['Recebido por', c.provedor === 'simulado' ? 'SIMULAÇÃO DE TESTE — sem valor real' : c.provedor],
  ];
  let y = 30;
  for (const [a, b] of linhas) { doc.setFont('helvetica', 'bold'); doc.text(a, 12, y); doc.setFont('helvetica', 'normal'); doc.text(doc.splitTextToSize(b, 80), 66, y); y += 8; }
  doc.setFontSize(7.5); doc.setTextColor(120); doc.text('Gerado automaticamente pelo sistema a partir da confirmação do pagamento.', 12, y + 6);
  doc.save(`Comprovante Pix - ${codigoPasta}.pdf`);
}

/** Cartão na pasta quando o modo é "Pix gerado pelo sistema". */
export function PixDaPasta({ pastaId, codigoPasta, equipe, aoMudar }: { pastaId: string; codigoPasta: string; equipe: boolean; aoMudar: () => void }) {
  const { avisar } = useDialogos();
  const [lista, setLista] = useState<Cobranca[] | null>(null);
  const [qr, setQr] = useState('');
  const [ocupado, setOcupado] = useState(false);

  const carregar = useCallback(async () => {
    const { data } = await supabase.from('cobrancas_pix').select('*').eq('pasta_id', pastaId).order('criado_em', { ascending: false });
    setLista((data as Cobranca[]) ?? []);
  }, [pastaId]);
  useEffect(() => { carregar(); }, [carregar]);

  const pago = lista?.find((c) => c.status === 'pago');
  const valido = lista?.find((c) => c.status === 'pendente' && new Date(c.expira_em) > new Date());
  useEffect(() => {
    if (!valido) { setQr(''); return; }
    import('qrcode').then((Q) => Q.toDataURL(valido.copia_cola, { margin: 1, width: 220 })).then(setQr).catch(() => setQr(''));
  }, [valido?.copia_cola]); // eslint-disable-line react-hooks/exhaustive-deps

  const gerar = async () => {
    setOcupado(true);
    const { error } = await supabase.rpc('gerar_cobranca_pix', { p_pasta: pastaId });
    setOcupado(false);
    if (error) avisar(error.message.includes('PROVEDOR_NAO_CONFIGURADO') ? 'O banco do Pix ainda não foi configurado. Use o comprovante anexado por enquanto.' : 'Não foi possível gerar o Pix.', 'erro');
    await carregar(); aoMudar();
  };
  const simular = async (c: Cobranca) => {
    const { error } = await supabase.rpc('simular_pagamento_pix', { p_cobranca: c.id });
    if (error) avisar('Não foi possível simular.', 'erro'); else avisar('Pagamento simulado.');
    await carregar(); aoMudar();
  };

  if (!lista) return null;
  return (
    <div className="cartao pix-cartao">
      <div className="cartao-topo">
        <div><h3>Pix do sinal</h3><p className="sub">O pagamento é confirmado automaticamente; não é preciso anexar comprovante.</p></div>
        {pago ? <span className="selo sp-aprovada">Pago</span> : valido ? <span className="selo sp-aguardando_analise">Aguardando pagamento</span> : <span className="selo sp-incompleta">Não gerado</span>}
      </div>
      {pago ? (
        <div className="pix-pago">
          <CheckCircle2 size={22} />
          <div><strong>{real(pago.valor)} pago em {pago.pago_em ? formatarDataHora(pago.pago_em) : '—'}</strong><br /><span className="sub">por {pago.pagador_nome ?? '—'}{pago.provedor === 'simulado' && ' · simulação de teste'}</span></div>
          <button type="button" className="botao" onClick={() => baixarComprovante(pago, codigoPasta)}><Download size={16} /> Comprovante</button>
        </div>
      ) : valido ? (
        <div className="pix-gerado">
          {qr ? <img src={qr} alt="QR Code do Pix" width={180} height={180} /> : <QrCode size={120} />}
          <div className="pix-info">
            <strong>{real(valido.valor)}</strong>
            <span className="sub">Vale até {formatarDataHora(valido.expira_em)}{valido.provedor === 'simulado' && ' · PIX DE TESTE, não pague'}</span>
            <textarea readOnly rows={3} value={valido.copia_cola} />
            <div className="acoes">
              <button type="button" className="botao" onClick={() => { navigator.clipboard?.writeText(valido.copia_cola); avisar('Pix copia e cola copiado.'); }}><Copy size={16} /> Copiar Pix copia e cola</button>
              <button type="button" className="botao" onClick={() => { carregar(); aoMudar(); }}><RefreshCw size={16} /> Atualizar</button>
              {equipe && valido.provedor === 'simulado' && <button type="button" className="botao" onClick={() => simular(valido)}>Simular pagamento (teste)</button>}
            </div>
          </div>
        </div>
      ) : (
        <div className="acoes">
          {lista.length > 0 && <span className="sub pix-dica">O Pix anterior venceu. Gere um novo para enviar ao cliente.</span>}
          <button type="button" className="botao principal" disabled={ocupado} onClick={gerar}><QrCode size={16} /> {ocupado ? 'Gerando…' : 'Gerar Pix do sinal'}</button>
        </div>
      )}
    </div>
  );
}
