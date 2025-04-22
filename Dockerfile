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
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN gem update --system && gem install bundler

# Set the working directory
WORKDIR /app

# Copy the Gemfile and Gemfile.lock into the working directory
COPY Gemfile Gemfile.lock ./

RUN bundle config build.nokogiri --use-system-libraries

# Install the gems
RUN bundle install

# Copy the rest of the application code into the working directory
COPY . .

# Expose the port the app will run on
EXPOSE 3000

# Start the application server
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
