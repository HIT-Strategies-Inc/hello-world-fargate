const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ 
    status: 'error', 
    message: 'Internal server error',
    timestamp: new Date().toISOString()
  });
});

// Serve static files
app.use(express.static('public'));

// Serve the main page
app.get('/', (req, res) => {
  try {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
  } catch (error) {
    console.error('Error serving index.html:', error);
    res.status(500).json({ 
      status: 'error', 
      message: 'Failed to serve main page',
      timestamp: new Date().toISOString()
    });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  try {
    res.status(200).json({ status: 'healthy', timestamp: new Date().toISOString() });
  } catch (error) {
    console.error('Health check error:', error);
    res.status(500).json({ 
      status: 'unhealthy', 
      timestamp: new Date().toISOString()
    });
  }
});

// Only start listening if not in test environment
if (require.main === module) {
  app.listen(PORT, '0.0.0.0', (err) => {
    if (err) {
      console.error('Failed to start server:', err);
      process.exit(1);
    }
    console.log(`Hello World app listening on port ${PORT}`);
    console.log(`Health endpoint available at: http://localhost:${PORT}/health`);
  });
}