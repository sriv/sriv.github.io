--- 
layout: post
title: "Ruby on Rack, Datamapper and Thin "
comments: true
tags:
- ruby
- rack
- datamapper
- thin
---

A while back I started a hobby project and wanted to try out a different tech stack, than the regular .net mvc or rails that I'm used to.

And I was also looking for something very lightweight. I've used Rack as a middleware with rails application before, but not on its own. Although I was aware of Rack being capable of serving HTTP request on its own.

I had a look at Sinatra as well, which is something I've played around briefly, might get around to writing some Sinatra based app sometime soon.

Ok, so starting with Rack, I had to achieve the below goals

- Create routes
- Serve static content
- Serve content from database
- Keep the endpoints secure (https).

###Routing
Rack enables one to create a `Proc` and execute it when invoked, via `map` method.

An example of defining a Rack route would be something like

    map "/hello" do
	    run Proc.new {|env| [200, {"Content-Type" => "text/plain"}, "Hello world!"]}
    end

If one were to put this in the `config.ru` file, fire up the app using `rackup`, it would expose `localhost:<port>/hello` as an endpoint that returns "Hello World".

So far so good, now how do we tell Rack to do something beyond "Hello World" ?

I did this by creating a class that would take a request and process it. An example class that looks up a user would be like this 

    class UserLookup
    
	    def call(env)
		    load_messages	
		    @req = Rack::Request.new(env)
		    if @req.get?
			    user = User.first(:employee_id => @req.GET['employee_id'])
			    return [404, {"Content-Type" => "text/plain"}, [@messages["unrecognized_user"]]] if user.nil? 
			    [200, {"Content-Type" => "text/plain"}, [user.to_json(:methods => [:reserved_books, :full_name, :interests])]]
		    else
			    [405, {"Content-Type" => "text/plain"}, [@messages[405]]]
		    end
	    end

	    private

	    def load_messages
	      @messages = YAML::load(File.read(File.expand_path('config/en.yml','.')))
	    end

    end

In `config.ru` add a mapping for this lookup like this

    map "/user" do
	    run UserLookup.new
    end

Now this exposes another endpoint that would look like

    localhost:<port>/user

Now, the `UserLookup` class needs to be designed to accept parameters. One way of sending the parameters is via querystring in the request. Rack request can lookup querystring using GET object.

###Nested Routes
Nesting routes with Rack is simple enough

    map "/foo" do
    	map "/bar" do
    		run FooBar.new
    	end
    	map "/baz" do
    		run FooBaz.new
    	end
    end
    
This will expose a "/foo/bar" and a "/foo/baz" endpoints. 

###Serving Static Content
Ok, so now we have all the requests hitting our application and each Route mapping invokes a Rack process. But like all other web applications, we have static resources to serve as well. In order to serve static content via Rack, it takes a different kind of mapping, like below -

    map "/scripts" do
    	run Rack::Directory.new(File.expand_path("./scripts"))
    end
    
    map "/css" do
    	run Rack::Directory.new(File.expand_path("./css"))
    end
    
    map "/img" do
    	run Rack::Directory.new(File.expand_path("./img"))
    end
    
And that's all it takes to serve all the content for a web application.

###Setup Thin webserver. 
Thin is a web server that is designed for higher throughput. More about Thin is available [here
](http://code.macournoyer.com/thin/). Just adding the `thin` gem in the `GemFile` and doing a `bundle install` was enough to setup Thin for me. By default `rackup` opens up the application using Webrick. Installing `Thin` gem launches the application using Thin.

###Why Thin?
There are various selling points for Thin. There is a comparison between the number of concurrent requests Thin can serve versus Mongrel, Webrick etc. So high concurrency is reason good enough.

My motive was simple - I needed to have my website running under SSL (https), this was because my web application access the webcamera of the user using Webkit's `webkitGetUserMedia` API, and it is annoying how everytime there is a call to this API, the browser asks for confirmation. Secure sites require confirmation only once, and the browser (Chrome) remembers the action in subsequent requests.

Thin comes with an option to enable SSL, so why not use it?

Enabling SSL over Thin is straightforward enough. As a first step I had to generate a self-signed certificate.

After that all I had to do was start Thin from the same directory as `config.ru` using these options

thin start --ssl --ssl-key-file ../cert/server.key --ssl-cert-file ../cert/server.crt

In absence of Thin, the other way to setup SSL is to have the application behind an `nginx` proxy and have `nginx` configured to use SSL.

###Data access - Datamapper
I'll not repeat stuff here, I think Datamapper's website is elaborate enough to highlight "[Why Datamapper?](http://datamapper.org/why.html)"

However, I do want to put down my experiences using Datamapper (beyond regular table mappings). But that is possibly a different post in itself, this one has got long enough. 

One thing I can say is I am in love with Datamapper, especially since, these days, most of my ORM time is consumed by NHibernate!




