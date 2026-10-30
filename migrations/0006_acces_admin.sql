-- portee: validation
-- Accès complet pour Coco et Elsa (décision de Coco du 30/10/2026). Les autres administrateurs
-- de Suivi des temps n'ont pas de ligne : consultation.
-- Les identifiants contiennent des prénoms et le dépôt est public : on les désigne par leur empreinte md5.
insert into planning.acces_admin (admin_id, niveau)
select a.admin_id, 'complet'
from public.admins a
where md5(a.admin_id) in ('7d32a5975cd6fb9a3ac2bfd05d9db2e8', '507c8559e6cfa837f9a3603778159de9');

do $$
begin
  if (select count(*) from planning.acces_admin) <> 2
     and current_setting('planning.banc_test', true) is distinct from 'oui' then
    raise exception 'Accès complet : 2 administrateurs attendus, % trouvés', (select count(*) from planning.acces_admin);
  end if;
end $$;
