import { createRoot } from 'react-dom/client';
import { Publico } from './Publico';
import { TV } from './TV';
import { Painel } from './Painel';
import { MeetingPublico } from './Meeting';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import './estilo.css';

// Rotas: "/" link público, "/tv" salão de vendas, "/painel" equipe, imobiliárias e corretores
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
// "/meeting/<endereço>": página pública de inscrição no meeting
const slugMeeting = rota.match(/^\/meeting\/([a-z0-9-]+)$/)?.[1];
const Pagina = rota === '/tv' ? TV : painel ? Painel : slugMeeting ? () => <MeetingPublico slug={slugMeeting} /> : Publico;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : painel ? 'painel' : slugMeeting ? 'meeting' : 'publico';

// Faixa de aviso quando não é a produção (ex.: v2 em testes)
const ambiente = import.meta.env.VITE_AMBIENTE as string | undefined;
if (ambiente) {
  const faixa = document.createElement('div');
  faixa.className = 'faixa-ambiente';
  faixa.textContent = ambiente;
  document.body.prepend(faixa);
}

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
