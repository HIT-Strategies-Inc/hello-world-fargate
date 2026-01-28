# Use official Node.js runtime (slim variant for ARM64 compatibility)
FROM node:18-slim

# Set the working directory in the container
WORKDIR /app

# Copy package.json and package-lock.json (if available)
COPY package*.json ./

# Install app dependencies
RUN npm install --production

# Copy the rest of the application code
COPY . .

# Create a non-root user for security
RUN groupadd -r -g 1001 nodejs && useradd -r -g nodejs -u 1001 nodejs

# Change ownership of the app directory to the nodejs user
RUN chown -R nodejs:nodejs /app

USER nodejs

# Expose the port the app runs on
EXPOSE 3000

# Use the default command to start the app
CMD ["node", "server.js"]