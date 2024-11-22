#!/usr/bin/Rscript
library(sf) 
library(ncdf4)

# read in netCDF
ncid <- nc_open('schout_deb.nc')
plot_var = ncvar_get(ncid, 'depth') # should be a vector (assign in a time loop if need be)
#plot_var = ncvar_get(ncid, 'elev') # substitute for variable of interest


### =========== OPTION 1 (simple) ===============
### plot variable on Voronoi polygon
vor = st_read('spatial_files/deb_vor.shp', quiet=T)
vor['varname'] = plot_var # replace [varname] with "depth", "zeta", "temp", etc.
plot(vor['varname'], axes=T, lwd=.1)


### =========== OPTION 2  (medium) ===============
### plot variable on elements (after straight avging over nodes)
els = st_read('spatial_files/deb_elems.shp', quiet=T)

# verts is an num_elems x 4 matrix with the indices for each vertex (NA in 4th column for tris)
verts <- matrix(as.numeric(unlist(strsplit(els$nodes, split=','))), ncol=4, byrow=T)
verts[verts == -99] <- NA
els['varname'] <- apply(matrix(plot_var[c(verts)], ncol=4, byrow=F), 1, mean, na.rm=T)
plot(els['varname'], axes=T, lwd=.1)


