# Use the official Ruby image as a base
FROM ruby:3.1.7

ENV BUNDLE_PATH /gems

# Install dependencies
RUN apt-get update -qq && apt-get install -yq --no-install-recommends \
    build-essential \
    gnupg2 \
    less \
    git \
    libpq-dev \
    libxml2-dev \
    libxslt-dev \
    postgresql-client \
    libvips \
    curl \
    graphviz \
    clamdscan \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Configure clamdscan to connect to clamav service
RUN mkdir -p /etc/clamav && \
    echo "TCPSocket 3310" > /etc/clamav/clamd.conf && \
    echo "TCPAddr clamav" >> /etc/clamav/clamd.conf

# Install Node.js (LTS version)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN gem update --system && gem install bundler

# Set the working directory
WORKDIR /app

# Copy the Gemfile and Gemfile.lock into the working directory
COPY Gemfile Gemfile.lock ./

RUN bundle config build.nokogiri --use-system-libraries

# Install the gems
RUN bundle install

# Copy package.json for npm install
COPY package.json ./

# Install npm dependencies
RUN npm install

# Copy the rest of the application code into the working directory
COPY . .

# Build JavaScript assets
RUN npm run build

# Create non-root user for security
RUN useradd -m -u 1000 harmonic && \
    chown -R harmonic:harmonic /app /gems

# Switch to non-root user
USER harmonic

# Expose the port the app will run on
EXPOSE 3000

# Start the application server
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
