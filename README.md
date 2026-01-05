# lilshallot/tor
A fully capable Tor container for use primarily with docker and docker compose.

## Usage
A container image is provided, but it is reccomended to build the container yourself.

### (Optional) Build the Container
Clone the repository:
`git clone https://github.com/lilshallot/tor`
CD into the tor directory
`cd tor`
Build the container with docker
`docker build -t lilshallot/tor:0.0.1 .`
Tag the image to latest
`docker tag lilshallot/tor:0.0.1 lilshallot/tor:latest`
