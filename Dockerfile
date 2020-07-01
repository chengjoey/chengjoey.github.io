FROM jekyll/jekyll

WORKDIR /srv/jekyll

Add ./* /srv/jekyll/
Add ./_includes/* /srv/jekyll/_includes/
Add ./_layouts/* /srv/jekyll/_layouts/
ADD ./_posts/* /srv/jekyll/_posts/
ADD ./_sass/* /srv/jekyll/_sass/
Add ./_sass/ext/* /srv/jekyll/_sass/ext/
Add ./assets/css/* /srv/jekyll/assets/css/
Add ./assets/font/* /srv/jekyll/assets/font/
Add ./assets/js/* /srv/jekyll/assets/js/
Add ./assets/textures/* /srv/jekyll/assets/textures/
Add ./images/* /srv/jekyll/images/

# ADD ./404.html /srv/jekyll/
# Add texture.gemspec /srv/jekyll/
# ADD ./*.png /srv/jekyll/
# ADD ./*.md /srv/jekyll/
# ADD *.yml /srv/jekyll/


RUN bundle install

# RUN jekyll build