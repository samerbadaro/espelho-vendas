/**
 * Duo Haus: posição de cada apartamento na fachada real (modelo do estúdio, exportado do Revit/3ds Max).
 * Medidas em metros no sistema do modelo original (Z para cima); o espelho converte para o 3D da tela.
 * Andar tipo com 11 apartamentos, conforme a planta do pavimento tipo (chave = final da unidade):
 * 02, 01, 11, 10, 09 de um lado (11 no meio, avançado) e 03 a 08 do outro.
 */
export interface Vao { x0: number; x1: number; y: number; lado: -1 | 1 }
export interface LayoutModelo { url: string; lajes: Record<number, number>; vaos: Record<number, Vao>; peDireito: number }

const lajes: Record<number, number> = { 2: 7.86, 3: 11.51 };
for (let a = 4; a <= 17; a++) lajes[a] = Math.round((14.81 + (a - 4) * 3.2914) * 100) / 100;

export const DUO_HAUS: LayoutModelo = {
  url: '/modelos/duohaus.glb.gz',
  lajes,
  peDireito: 3.29,
  vaos: {
    // fachada da portaria (5 apartamentos; o final 11 é o do meio, avançado), da esquerda para a direita
    2: { x0: -14.7, x1: -10.4, y: 7.6, lado: 1 },
    1: { x0: -10.2, x1: -6.1, y: 7.2, lado: 1 },
    11: { x0: -5.6, x1: 2.9, y: 9.3, lado: 1 },
    10: { x0: 3.3, x1: 7.7, y: 7.2, lado: 1 },
    9: { x0: 7.9, x1: 12.2, y: 7.6, lado: 1 },
    // fachada oposta (6 apartamentos), na mesma ordem da planta: 03 a 08
    3: { x0: -14.0, x1: -10.4, y: -7.6, lado: -1 },
    4: { x0: -10.2, x1: -5.9, y: -8.5, lado: -1 },
    5: { x0: -5.7, x1: -1.4, y: -8.5, lado: -1 },
    6: { x0: -1.2, x1: 3.1, y: -8.5, lado: -1 },
    7: { x0: 3.3, x1: 7.7, y: -8.5, lado: -1 },
    8: { x0: 7.9, x1: 11.2, y: -7.6, lado: -1 },
  },
};
