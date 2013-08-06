--- 
layout: post
title: "Pragmatism and Purity"
comments: true
tags:
- meta
---

One of the lessons I've learnt from experience is that there are good systems, and there are bad systems. But they do the job for their users. The difference between good and bad comes into picture only when the systems fail to adapt or evolve at the same (if not faster pace) than the user's needs.

I am motivated to write this post by some of the messages exchanged between me and another user at [StackOverflow](http://stackoverflow.com/questions/14374075/timeout-connecting-to-sql-server-express-2012#comment20060455_14374075). The question admits inefficiencies in the system, and seeks a way to work within the limitations. Personal abuses aside, there is one school of thought that mandates drastic changes to fix the root cause. 

In reality, very few root causes are easily fixable. If they were, I'd expect them to be fixed already and all conversations around them would not be happening.

I've been involved in multiple transformation projects, where the challenge is to upgrade the system landscape without the users' lives being disrupted. Martin Fowler wrote about [Strangulation Pattern](http://martinfowler.com/bliki/StranglerApplication.html), where he gives out some points on how this could help in re-writing legacy applications. There is a discussion on [StackOverflow](http://stackoverflow.com/questions/1118804/application-strangler-pattern-experiences-thoughts) which has some good insights on the challenges and approach that can be taken to phase out an application.

On the practical front, there are various types of challenges, and not all of them are technical. But this is a bigger topic, and possibly worth another writeup.

### Some Observations 
* There is no perfect system. No matter how much you optimize, there is always going to be a few areas to improve upon. The main reason is Software development projects work towards a moving target - changing business.
* A purist is someone who is tempted to do everything by the book, to write the perfect peace of software. A lot of this is driven by the personal drive to write the best piece of code. A pragmatic programmer, on the other hand, is someone who can weigh both sides and decide on a balance. 
* No one has infinite time or resource. So there is always going to be someone who draws the line on how perfect the software needs to be. Worse still, once a project is marked as complete, only a subset of the time/resource spent earlier is spent on maintaining it. Hence, there will be someone taking a call to do features or technical maintenance, and in most case, maintenance is driven by business needs.

### In Summary
While purism is good, and purists have a place to criticize (constructively, of course) projects, almost all of the ones I've come across lack something more important (at least in my mind) - empathy. A little pragmatism goes a long way in achieving the goals, but not at the cost of technical compromise. There are often decisions made, shortcuts taken which will make a purist cry. But sometimes, situations demand it. The fact that people are crying out for help indicates the urgency involved. However, part of being pragmatic also means - Track the system's technical debt. Close the debt as soon as possible, else there is a heavy price to pay later.