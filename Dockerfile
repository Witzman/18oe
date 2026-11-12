# Walking skeleton (no engine, no frontend yet — see app.rb). Single stage
# for now; a frontend build stage (esbuild) joins this once web/ exists,
# per notes/reference/infrastructure-plan.md in 18oe-workshop.
FROM ruby:3.3-alpine

WORKDIR /app

RUN apk add --no-cache build-base

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY app.rb ./

ENV PORT=80
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1/healthz | grep -q ok || exit 1

CMD ["ruby", "app.rb"]
