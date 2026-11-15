import { createRoot } from 'react-dom/client';
import { Publico } from './Publico';
import { TV } from './TV';
import { Painel } from './Painel';
import { MeetingPublico } from './Meeting';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import { CadastroImobiliaria } from './Cadastro';
import './estilo.css';
import { baseAba, semBase } from './rotaEmp';

// Rotas: "/" link público, "/tv" salão de vendas, "/painel" equipe, imobiliárias e corretores
// "/e/<empreendimento>/painel/...": painel já dentro de um empreendimento
if (baseAba && semBase(window.location.pathname).replace(/\/+$/, '') === '') window.location.replace(`${baseAba}/painel`);
const rota = semBase(window.location.pathname).replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
// "/meeting/<endereço>": página pública de inscrição no meeting; "/cadastro": cadastro de imobiliária
const slugMeeting = rota.match(/^\/meeting\/([a-z0-9-]+)$/)?.[1];
const Pagina = rota === '/tv' ? TV : rota === '/cadastro' ? CadastroImobiliaria : painel ? Painel : slugMeeting ? () => <MeetingPublico slug={slugMeeting} /> : Publico;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : painel || rota === '/cadastro' ? 'painel' : slugMeeting ? 'meeting' : 'publico';

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
