Use an official Node runtime as a parent image

This gives us a minimal Linux environment with Node.js pre-installed.

FROM node:20-slim

Set the working directory in the container to /usr/src/app

All subsequent commands will be run relative to this directory inside the container.

WORKDIR /usr/src/app

Copy package.json and package-lock.json to the working directory

We do this first to leverage Docker's caching, only re-running 'npm install' if these files change

COPY package*.json ./

Install app dependencies

RUN npm install

Copy the rest of the application source code (server.js)

COPY . .

The application runs on port 3000, and we inform Docker about this

EXPOSE 3000

Define the command to run the app when the container starts

CMD [ "npm", "start" ]
