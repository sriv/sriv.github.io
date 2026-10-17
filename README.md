# sriv.github.io

Source for my site. GitHub Pages builds it with Jekyll on push.

Local preview:

    docker run --rm -p 4000:4000 -v "$PWD":/srv -w /srv ruby:3.3 \
      sh -c "bundle install && bundle exec jekyll serve --host 0.0.0.0"

Journal chapters live in `_posts/` with `period:` and `dek:` in the front matter.
Diagrams are inline SVG includes in `_includes/diagrams/`.
