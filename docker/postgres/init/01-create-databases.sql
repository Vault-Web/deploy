SELECT 'CREATE DATABASE vault_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'vault_db')\gexec

SELECT 'CREATE DATABASE cloud_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cloud_db')\gexec

SELECT 'CREATE DATABASE password_manager_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'password_manager_db')\gexec
