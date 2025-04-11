---
title: Schemata
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

prev_chapter:
  href: chapter2.html
  label: Setting up
  title: Setting up

next_chapter:
  href: chapter4.html
  label: Import OSM Data
  title: Import OSM Data

custom_toc:
  - {href: schemata, label: 3. Schemata}
  - {href: default-schemata, label: 3.1 Default schemata}
---

# 3. Schemata

*Schema* implements a logical separation between named relations within a
database. It contains tables, data types, functions, operators etc. Names within
the same schema are unique, but names within schemas do not have to be unique
along the database. Schemas are always top level and can not be nested.

Assuming privileges permit it, a user can access all the schemas of a database
maintaining the same connection.

Proper schema definition allows for:

 * User separation within the database
 * Object organization which is fundamental for data normalization
 * Application level version control, i.e. maintain a stable API across
   application versions.
 * Extension management

# 3.1 Default schemata

By default there are some schemas created.


```sql
=# \dnS+
                                                  List of schemas
        Name        |       Owner       |           Access privileges            |           Description            
--------------------+-------------------+----------------------------------------+----------------------------------
 information_schema | georgios          | georgios=UC/georgios                  +| 
                    |                   | =U/georgios                            | 
 pg_catalog         | georgios          | georgios=UC/georgios                  +| system catalog schema
                    |                   | =U/georgios                            | 
 pg_toast           | georgios          |                                        | reserved schema for TOAST tables
 public             | pg_database_owner | pg_database_owner=UC/pg_database_owner+| standard public schema
                    |                   | =U/pg_database_owner                   | 
(4 rows)
```

The main schema to query for information related to your database objects is
*pg_catalog*. It is always contained in the *search_path* when not explicitly
listed, it will implicitly queried *before* searching the schemas listed in the
search_path.

The basic difference between the *information_schema* and *pg_catalog* is that
the information_schema is that the information_schema is part of the SQL
standard and is stable across PostgreSQL major versions, whereas pg_catalog is a
postgres specific implementation and unstable across major versions.

