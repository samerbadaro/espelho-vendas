-- Vídeos do manual
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ begin
  begin perform salvar_video_manual('pastas', 'https://youtu.be/abc'); raise notice 'FALHOU  Sec. Vendas cadastrou vídeo';
  exception when others then raise notice 'OK      Só o administrador cadastra vídeo'; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ begin
  begin perform salvar_video_manual('pastas', 'http://inseguro.com/v'); raise notice 'FALHOU  link sem https aceito';
  exception when others then raise notice 'OK      Link precisa ser https'; end;
  perform salvar_video_manual('pastas', 'https://youtu.be/abc', 'Como montar a pasta');
  perform salvar_video_manual('pastas', 'https://youtu.be/xyz', 'Versão nova');
  raise notice '%  Vídeo trocado no mesmo capítulo', case when (select count(*) from manual_videos) = 1 and (select url from manual_videos) = 'https://youtu.be/xyz' then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  raise notice '%  Corretor vê os vídeos', case when (select count(*) from manual_videos) = 1 then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ begin
  perform salvar_video_manual('pastas', null);
  raise notice '%  Link vazio remove o vídeo', case when (select count(*) from manual_videos) = 0 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
