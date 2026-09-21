<?php
// Lit la config DB d'un .env Laravel avec phpdotenv (le parseur de Laravel :
// guillemets, échappements, commentaires en fin de ligne, $, #...), là où un
// grep/cut se trompe. Usage : php read-db-env.php <deploy_path>
// Sortie : 6 lignes base64 (connection, host, port, database, username,
// password) pour éviter tout problème de quoting côté shell.
$dir = $argv[1] ?? '';
if (!is_file($dir . '/vendor/autoload.php')) {
    fwrite(STDERR, "vendor/autoload.php introuvable\n");
    exit(2);
}
require $dir . '/vendor/autoload.php';
$env = Dotenv\Dotenv::createArrayBacked($dir)->safeLoad();
foreach (['DB_CONNECTION', 'DB_HOST', 'DB_PORT', 'DB_DATABASE', 'DB_USERNAME', 'DB_PASSWORD'] as $k) {
    echo base64_encode((string) ($env[$k] ?? '')), "\n";
}
