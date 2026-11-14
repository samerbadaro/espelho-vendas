import { createRoot } from 'react-dom/client';
import { Publico } from './Publico';
import { TV } from './TV';
import { Painel } from './Painel';
import { Proposta } from './proposta/Proposta';
import { ProvedorMarca, ProvedorDialogos } from './ui';
import './estilo.css';

// Rotas: "/" link público, "/tv" salão de vendas, "/painel" equipe, imobiliárias e corretores
const rota = window.location.pathname.replace(/\/+$/, '') || '/';
const painel = rota === '/painel' || rota.startsWith('/painel/');
// "/proposta": tela de proposta da v2, em testes (ainda não grava nada no banco)
const Pagina = rota === '/tv' ? TV : rota === '/proposta' ? Proposta : painel ? Painel : Publico;
document.body.dataset.pagina = rota === '/tv' ? 'tv' : painel || rota === '/proposta' ? 'painel' : 'publico';

createRoot(document.getElementById('root')!).render(
  <ProvedorMarca>
    <ProvedorDialogos>
      <Pagina />
    </ProvedorDialogos>
  </ProvedorMarca>,
);
