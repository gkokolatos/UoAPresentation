---
title: Introduction
author: Georgios Kokolatos
date: 11th of April, 2025

custom_chapters:
  - {href: chapter1.html, label: Introduction}
  - {href: chapter2.html, label: Setting up}
  - {href: chapter3.html, label: Schemata}
  - {href: chapter4.html, label: Import OSM Data}
  - {href: chapter5.html, label: Vehicle log}
  - {href: chapter6.html, label: Emergencies}
  - {href: chapter7.html, label: Schema Testing}
  - {href: chapter8.html, label: Application Interface}
  - {href: chapter9.html, label: Generating vehicle data}
  - {href: chapter10.html, label: Routing}

next_chapter:
  href: chapter2.html
  label: Getting started
  title: Getting Started

custom_toc:
  - {href: introduction, label: 1. Introduction}
  - {href: the-problem, label: 1.1 The problem}
---


# 1. Introduction

* Who am I
* Why am I here

## 1.1 The problem

Design and implement the database portion of an emergency vehicles fleet
management system. The user should be able to know how many vehicles are
present, their current location, whether they are involved in an incident,
and which vehicle is closest to an incident's location. The user's manager
would like to able to derive basic statistics about the fleet's past
performance.

### Prerequisites

* Basic coding experience
* Basic understanding of SQL
* Some previous knowledge of PostgreSQL and PostGIS

### What will we cover

* Custom functions
* Importing and using OSM data
* Schema design 
* Suitable datatypes
* Triggers and constraints
* Using routing algorithms
* Views
