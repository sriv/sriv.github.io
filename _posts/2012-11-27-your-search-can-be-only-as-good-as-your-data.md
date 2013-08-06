--- 
layout: post
title: "Your search can be only as good as your data"
comments: true
tags:
- search
---

Very recently I was involved in a project that required us to implement a search feature. The setup is quite simple, and generic:

1) An Administration Application - Responsible for authoring/creating products and its attributes.

2) A catalogue application that also powers the public facing website, which has details about products.

In this project, the product managers have been consolidating Product details in their respective areas for a while (a few years). We were tasked with retrofitting the search engine to use the data.

Seems simple enough ? Here are few points that I learnt from this task.

###Data issues can exist at all level
###*Storage/Design*

Bad data isn't just about ***wrong data types***. Number stored as string, data-time woes combined with time zone complexities can be a data warehouse nightmare. Often, we had to add ad-hoc conditions to the data extraction logic.

***Data integrity*** is another case, where legacy databases which have grown in an ad-hoc fashion, often as a result of silo-ed application development. This causes cross database lookup, often not protected by foreign keys and such. 

With such atomic databases being out of sync, data is duplicated and not in it's entirety. So ***de-duplication*** of data is one of the overheads. 

###*Human Error*
Most data collection mechanisms involve manual entry. ***Mis-spelling, mis-tagging, mis-classification etc. can have catastrophic effect*** in the long run. The effect is magnified when dependencies on such data get added. Not only the entity itself is polluted, but it ends up affecting the entire chain.

Humans can be easily misguided, and lack of training can only make it worse. In some cases, excessive tagging is perceived as something that would boost up the product. Product managers have been religiously doing this. What they do not realize is ***too much data is noise***, it is pollution.

###Conclusion

Bad data can be caused due to bad design or poor data capture mechanism. Sometimes, bad data can be curated by manual tasks. Some other times, there are patterns of bad data, and some automated tasks can help clean it up. However, there is a good chance that the data is not cleaned up at all. 

No matter what tool/technology one looks at (be it Search tools like SOLR, or other data-warehouse tools) , the bottleneck in getting the right Search (or any analytics) is going to be data quality. These tools are mature enough to be close to perfect, given the perfect dataset. So, whenever there is a mismatch in expected v/s actual behaviour, I would first look at the data. Most problems/bugs that I have faced implementing a Search is because of bad data.
