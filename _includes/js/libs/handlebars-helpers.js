Handlebars.registerHelper('lastfm_text', function(obj) {
  try {
    return obj['#text'];
  } catch (err) {
    return '';
  }
});

Handlebars.registerHelper('lastfm_image_url', function(obj) {
  try {
    return obj[0]['#text'];
  } catch (err) {
    return '';
  }
});

Handlebars.registerHelper('lastfm_avatar_url', function(obj) {
  try {
    return obj[1]['#text'];
  } catch (err) {
    return '';
  }
});