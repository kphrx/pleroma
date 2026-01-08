# Dashboards

Pleroma comes with two types of backend dashboards viewable to instance administrators:

* [Phoenix LiveDashboard](https://hexdocs.pm/phoenix_live_dashboard/Phoenix.LiveDashboard.html) - A general system oriented dashboard for viewing statistics about Pleroma resource consumption, Pleroma's database and Pleroma's job processor (Oban).
* [Oban Web](https://hexdocs.pm/oban_web/overview.html) - A dashboard specific to Oban for viewing Oban statistics, managing jobs and job queues.

!!! note
    Both dashboards require working Websockets.  
    If your browser or web server don't support Websockets, both dashboards either won't update or will not display all information.

## Phoenix LiveDashboard

Instance administrators can access this dashboard at `/phoenix/live_dashboard`, giving a simple overview of software versions including Erlang and Elixir versions, instance uptime and resource consumption.

This dashboard gives insights into the current state of the BEAM VM running Pleroma code and database statistics including basic diagnostics.
It can be useful for troubleshooting of some issues namely regarding database performance. 

### Relevant dashboard tabs

* Home - A general overview of system information including software versions, uptime and memory BEAM memory consumption.
* OS Data - Information about the OS and system such as CPU load, memory usage and disk usage.
* Ecto Stats - Information about the Pleroma database.
    - Diagnose - Basic database diagnostics, including a `bloat` warning when an index or a table have excessive bloat, which can lead to bad database performance.
    - Bloat - A table showing size of "bloat" (unused wasted space) in database tables and indexes. Very high bloat size in the `activities` and `objects` tables can lead to bad performance especially on slower disks such as on most VPS providers.
    - Db settings - A small list of PostgreSQL settings mostly relevant to database performance.
    - Total table size - Shows sizes of all database tables including indexes sorted by size, useful for quickly checking overall database size.
    - Long running queries - A list of of slow database queries and their duration. Multiple entries with duration in multiple seconds indicate a slowly performing database.
* Oban - Shows a list of all Oban jobs.

!!! note
    The DB bloat warning for `index 'oban_jobs::oban_jobs_args_index'` in Ecto Stats can be safely ignored.

## Oban Web

An advanced dashboard and management console viewable to instance administrators specifically for Oban, Pleroma's job processor.
It allows managing jobs, including force retrying failed jobs and job deletion.  
It can be accessed at `/pleroma/oban`.

!!! danger
    This dashboard is very powerful! If you are unsure what a certain feature does, don't use it.  
    Changing individual queue state/settings in the "Queues" view is heavily discouraged.

* Shows a real time chart of either a number of executed jobs, or job execution/wait time per a given time frame and the state/queue/worker.
* Shows a list of jobs in each state, their argument, number of attempts and execution/scheduled time.
* Selecting one or multiple jobs in the list allows performing actions like canceling/deleting and retrying.
* Clicking on a job shows a detailed view including the full argument, when it was inserted, information about its attempts, and performing actions on it.
