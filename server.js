const express = require('express');
const app = express();

// We are intentionally setting the port to 3000 here, 
// which must match the 'Application Port' input in deploy.sh.
const PORT = 3000;
const HOST = '0.0.0.0'; 

app.get('/', (req, res) => {
  console.log('Request received for /');
  res.send('<h1>Hello from the Dockerized Node.js App!</h1><p>Deployment successful via Automated Bash Script!</p>');
});

app.listen(PORT, HOST, () => {
  console.log(`Running on http://${HOST}:${PORT}`);
});
