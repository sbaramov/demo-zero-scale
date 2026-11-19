INSERT INTO projects (name, description)
SELECT 'Zero-Scale Article', 'Demo tasks for the Istio + KEDA + Project Leyden article'
WHERE NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');

INSERT INTO projects (name, description)
SELECT 'Personal Errands', 'Everyday tasks organized by project'
WHERE NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Set up k3d cluster with Istio and KEDA', true
FROM projects p
WHERE p.name = 'Zero-Scale Article'
  AND NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Benchmark Project Leyden AOT cold start', false
FROM projects p
WHERE p.name = 'Zero-Scale Article'
  AND NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');

INSERT INTO tasks (project_id, title, completed)
SELECT p.id, 'Pick up coffee beans', false
FROM projects p
WHERE p.name = 'Personal Errands'
  AND NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');

INSERT INTO app_seed_history (seed_name)
SELECT 'initial-seed'
WHERE NOT EXISTS (SELECT 1 FROM app_seed_history WHERE seed_name = 'initial-seed');
