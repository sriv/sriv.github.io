templates = {}

numberWithCommas = (x) ->
  return x.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")

load_template = (template_name, callback) ->
  $.ajax
    url: "{{site.url}}/templates/#{template_name}.tpl"
    success: (data) ->
      templates[template_name] = Handlebars.compile(data)
      callback()

show_profile = (profile_name, context) ->
  modal = $(templates[profile_name](context))
  $("body").append(modal)
  close_all_modals()
  modal.find(".timeago-instagram").each ->
    $(this).attr('title', new Date($(this).attr('title') * 1000).toISOString())
  modal.find(".timeago").timeago()
  modal.modal('show')

  $("##{profile_name}-link").parent().removeClass('loading')

close_all_modals = ->
  $(".modal.in").modal('hide')

show_twitter = ->
  twitter_modal = $(".twitter.modal")
  if twitter_modal.length
    close_all_modals()
    return twitter_modal.modal('show')

  $("#twitter-link").parent().addClass('loading')

  load_template 'twitter', ->

    $.ajax
      url: "http://api.twitter.com/1/statuses/user_timeline.json?include_rts=true&include_entities=true&screen_name={{site.twitter}}"
      dataType: "jsonp"
      success: (data) ->
        $(data).each ->
          this.text = linkify_entities(this)

        show_profile 'twitter',
          user:
            name: data[0].user.name
            screen_name: data[0].user.screen_name
            profile_image_url: data[0].user.profile_image_url
            f_description: data[0].user.description
            location: data[0].user.location
            url: data[0].user.url

            statuses_count: data[0].user.statuses_count
            friends_count: data[0].user.friends_count
            followers_count: data[0].user.followers_count

          tweets: data

show_github = ->
  github_modal = $(".github.modal")
  if github_modal.length
    close_all_modals()
    return github_modal.modal('show')

  $("#github-link").parent().addClass('loading')

  load_template 'github', ->

    $.ajax
      url: "https://api.github.com/users/{{site.github}}"
      dataType: "jsonp"
      success: (user_data) ->

        $.ajax
          url: "https://api.github.com/users/{{site.github}}/repos"
          dataType: "jsonp"
          success: (repo_data) ->
            show_profile 'github',
              user: user_data.data
              repos: repo_data.data


show_instagram = ->
  instagram_modal = $(".instagram.modal")
  if instagram_modal.length
    close_all_modals()
    return instagram_modal.modal('show')

  $("#instagram-link").parent().addClass('loading')

  load_template 'instagram', ->

    $.ajax
      url: "https://api.instagram.com/v1/users/{{site.instagram_id}}?access_token=18360510.f59def8.d8d77acfa353492e8842597295028fd3"
      dataType: "jsonp"
      success: (user_data) ->

        $.ajax
          url: "https://api.instagram.com/v1/users/{{site.instagram_id}}/media/recent?access_token=18360510.f59def8.d8d77acfa353492e8842597295028fd3"
          dataType: "jsonp"
          success: (photo_data) ->
            show_profile 'instagram',
              user: user_data.data
              media: photo_data.data


show_dribbble = ->
  dribbble_modal = $(".dribbble.modal")
  if dribbble_modal.length
    close_all_modals()
    return dribbble_modal.modal('show')

  $("#dribbble-link").parent().addClass('loading')

  load_template 'dribbble', ->
    $.ajax
      url: "http://api.dribbble.com/players/{{site.dribbble}}/shots"
      dataType: "jsonp"
      success: (data) ->
        show_profile 'dribbble',
          shots: data.shots
          user: data.shots[0].player

show_lastfm = ->
  lastfm_modal = $(".lastfm.modal")
  if lastfm_modal.length
    close_all_modals()
    return lastfm_modal.modal('show')

  $("#lastfm-link").parent().addClass('loading')

  load_template 'lastfm', ->
    $.ajax
      url: "http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user={{site.lastfm}}&api_key={{site.lastfm_api_key}}&format=json"
      dataType: "jsonp"
      success: (track_data) ->

        $.ajax
          url: "http://ws.audioscrobbler.com/2.0/?method=user.getinfo&user={{site.lastfm}}&api_key={{site.lastfm_api_key}}&format=json"
          dataType: "jsonp"
          success: (user_data) ->

            user_data.user.formatted_plays = numberWithCommas(user_data.user.playcount);
            user_data.user.formatted_playlists = numberWithCommas(user_data.user.playlists);
            user_data.user.formatted_register_date = moment(user_data.user.registered['#text'], 'YYYY-MM-DD HH:mm').format('MM/DD/YYYY');

            $.each track_data.recenttracks.track, (i, t) ->
                # Lastfm can be really finicky with data and return garbage if
                # the track is currently playing
                try
                  date = t.date['#text']
                catch err
                  t.formatted_date = 'Now Playing';
                  return true # equivalent to 'continue' with a normal for loop

                t.formatted_date = moment.utc(date, 'DD MMM YYYY, HH:mm').fromNow();


            show_profile 'lastfm',
              user_info: user_data
              recenttracks: track_data

show_soundcloud = ->
  soundcloud_modal = $(".soundcloud.modal")
  if soundcloud_modal.length
    close_all_modals()
    return soundcloud_modal.modal('show')

  $("#soundcloud-link").parent().addClass('loading')

  load_template 'soundcloud', ->
    $.ajax
      url: "http://api.soundcloud.com/users/{{site.soundcloud}}/tracks.json?client_id={{site.soundcloud_api_key}}"
      dataType: "jsonp"
      success: (track_data) ->
        $.ajax
          url: "http://api.soundcloud.com/users/{{site.soundcloud}}.json?client_id={{site.soundcloud_api_key}}"
          dataType: "jsonp"
          success: (user_data) ->
            show_profile 'soundcloud',
              user_profile: user_data,
              user_tracks:
                tracks: track_data,
                show_artwork: "true" is "{{site.soundcloud_show_artwork}}",
                player_color: '#ffffff'


first_active = false

set_active_nav = (el) ->
  nav = $("#links")

  if !first_active
    first_active = nav.find("li.active")

  nav.find("li").removeClass("active")
  el.addClass("active")

reset_active_nav = ->
  nav = $("#links")
  nav.find("li").removeClass("active")
  if first_active then first_active.addClass("active")

$(document).on "click", "#twitter-link", show_twitter
$(document).on "click", "#github-link", show_github
$(document).on "click", "#instagram-link", show_instagram
$(document).on "click", "#dribbble-link", show_dribbble
$(document).on "click", "#lastfm-link", show_lastfm
$(document).on "click", "#soundcloud-link", show_soundcloud

$(document).on "show", ".profile.modal", ->
  profile_name = $(this).attr('id').match(/(.*)\-/)[1]
  set_active_nav($("##{profile_name}-link").parent())

$(document).on "show", ".post.modal", ->
  page_name = $(this).data('page-name')
  set_active_nav($("a[data-page-name=#{page_name}]").parent())

$(document).on "hide", ".profile.modal, .post.modal", ->
  reset_active_nav()

$(document).on "click", "ul#links a.static-page", (e) ->
  e.preventDefault()
  el = $(this)
  page_name = el.data('page-name')
  existing_modal = $(".modal[data-page-name=#{page_name}]")

  if existing_modal.length > 0
    close_all_modals()
    return existing_modal.modal('show')

  el.parent().addClass('loading')

  $.ajax
    url: el.attr('href')
    success: (data) ->
      post = $(data).find("li.post")
      modal = $("""
        <div class='modal post' data-page-name='#{page_name}'>
          <button class="close" data-dismiss="modal">×</button>
        </div>
      """)
      modal.append(post)
      $("body").append(modal);
      el.parent().removeClass('loading')
      close_all_modals()
      modal.modal('show');

$ ->
  $(".loading-spinner").spin
    lines: 9
    length: 5
    width: 2
    radius: 4
    rotate: 9
    color: '#4c4c4c'
    speed: 1.5
    trail: 40
    shadow: false
    hwaccel: false
    className: 'spinner'
    zIndex: 2e9
