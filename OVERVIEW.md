# Remote Desktop

## What it is

A Linux desktop that runs on a remote machine and appears in your browser tab.
Windows, a mouse pointer, a terminal — an ordinary graphical desktop, except
that it is running somewhere else and being drawn for you over the network.

Nothing is installed on your side. Any modern browser works, and the session
survives you closing the tab: reopen the link and your windows are where you
left them.

## Use cases

- Running a graphical program that has no web version and cannot be installed
  locally — a visualisation tool, an instrument's control software, a licensed
  application tied to a particular machine.
- Working with graphical software that needs to sit next to large data on a
  cluster rather than pulling that data across the network.
- Giving someone a working environment without asking them to install
  anything, on a machine you do not control.
- Serving as the starting point for a purpose-built graphical app; the object
  detection desktop apps are built on this skeleton.

## What's included

- A desktop session with a window manager and a terminal.
- Everything needed to deliver it to a browser and keep it private to you.

On its own this is a plain desktop, kept deliberately minimal. It is a
foundation: install a graphical program on top of it and that program is what
users see.

## Where it can run

- **On your own computer**, through Docker.
- **On a research cluster**, through Apptainer/Singularity, as an interactive
  job on a compute node.
- **Through a science gateway**, which starts the session and hands you the
  link.

It runs entirely under a normal user account, with no special privileges, which
is what makes it acceptable on shared systems. Only one network port is
exposed, and the session is protected by a secret unique to it.

## Getting started

Start the container and open the private link it prints. The desktop appears in
the tab.

Through a gateway the link comes to you directly.

Closing the tab leaves the session running, which is intentional — a dropped
connection should not cost you your work. Ending a session is therefore a
separate, deliberate act; how depends on how it was started, and the
repository's README covers it.
