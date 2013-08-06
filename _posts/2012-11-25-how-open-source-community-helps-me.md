--- 
layout: post
title: "How open source community helps me"
comments: true
tags:
- open-source
- meta
---

There has been a lot of buzz about open-source software lately. Thanks to sites like [github](http://www.github.com), more and more people are looking at open-source software, and thankfully, the contributing community also seems to be growing.

Events like [FOSS](http://www.foss.in) helps promote awareness of open source software in India, where majority of the developers are working for companies that handle large 'enterpricey' clients.

Up until a few years ago, I belonged to the above mentioned category of developers. I have had my fair share of projects that I am not proud of. It is not so much the nature of work that I am complaining, but the environment. I have worked for clients from various parts of the world and each one of them had different kind of restrictions. 'Trust' was almost non-existent. In fact, one of the clients denied me internet access.

In the above mentioned eco-system, I did manage to learn some stuff that kept my interests. Nevertheless, if I were to assess myself as a programmer today, I will say that I am still not half as good as I'd like to be. My list of topics of interest is growing by the day (and I hope that is a good thing!).

So, if the infrastructure was not there, how was I to know whether I was writing code the right way? More importantly, how would I know if I am wasting my time re-inventing the wheel? Most importantly, how would I learn from the experts?

One thing that has always helped me is - read others' code. I have come across code that blows my mind away, and code that makes me cry. 

More important than learning any language, is to be aware of the eco-system that exists around a language. In a consulting world, productivity matters. It matters for the clients, but even more it matters to me. 

Open source community (and by that I mean various projects/people) have shown me different paths and solutions to various problems.

###An example

Take this blog, it uses [pretzel](https://github.com/code52/pretzel). I have been encouraged/nagged by various colleagues/friends to start a blog, but I have managed to procrastinate so far. When I finally got around to getting started, I wanted to have a light platform.

Github pages/Jekyll was a choice, but I wanted something with a .NET flavour. I found [pretzel](https://github.com/code52/pretzel), and immediately fell in love with it.

Now I could have just downloaded the program, and used it. It has an excellent wiki.

But I decided to look at the code. And that is when I realized the guys were using [Firefly](http://github.com/loudej/firefly), a very light HTTP server built on .NET. This has given me a spark - I write a lot of tests (I practise TDD and Continuous Integration). Firefly could be something worth investigating as a replacement to IIS in at least some tests. This could save some deploy and configuration time!

Now that was one lesson learnt. The other neat tool I came to know was [MarkPad](https://github.com/Code52/DownmarkerWPF). This is a neat tool to edit markdown, with side by side preview. A simple idea, well executed. Thanks again to Code52 guys.

###Conclusion

What started off as a hunt for a blogging tool in .NET, not only led me to an answer (i.e Pretzel), but also led me to two other tools, that will come handy in other situations. This is good enough to keep me motivated to go through more such code online. At some point I wish to be in a more active(read contributing) state in this open source community than I am today.
