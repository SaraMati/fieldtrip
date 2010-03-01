function peerslave(varargin)

% PEERSLAVE starts the low-level peer services and switches to slave mode.
% Subsequently it will wait untill a job comes in and execute it.
%
% Use as
%   peerslave(...)
%
% Optional input arguments should be passed as key-value pairs and can include
%   maxnum     = number (default = inf)
%   maxtime    = number (default = inf)
%   sleep      = number in seconds (default = 0.01)
%   memavail   = number, amount of memory available       (default = inf)
%   cpuavail   = number, speed of the CPU                 (default = inf)
%   timavail   = number, maximum duration of a single job (default = inf)
%   threads    = number, maximum number of threads to use (default = automatic)
%   allowhost  = {...}
%   allowuser  = {...}
%   allowgroup = {...}
%   fairshare  = [a, b, c, d]
%   group      = string
%   hostname   = string
%
% See also PEERMASTER, PEERRESET, PEERFEVAL, PEERCELLFUN

% get the optional input arguments
maxnum     = keyval('maxnum',     varargin); if isempty(maxnum),   maxnum=inf; end
maxtime    = keyval('maxtime',    varargin); if isempty(maxtime),  maxtime=inf; end
sleep      = keyval('sleep',      varargin); if isempty(sleep),    sleep=0.01; end
memavail   = keyval('memavail',   varargin);
cpuavail   = keyval('cpuavail',   varargin);
timavail   = keyval('timavail',   varargin);
fairshare  = keyval('fairshare',  varargin);
threads    = keyval('threads',    varargin);
allowhost  = keyval('allowhost',  varargin); if isempty(allowhost), allowhost = {}; end
allowuser  = keyval('allowuser',  varargin); if isempty(allowuser), allowuser = {}; end
allowgroup = keyval('allowgroup', varargin); if isempty(allowgroup), allowgroup = {}; end
hostname   = keyval('hostname',   varargin);
group      = keyval('group',      varargin);

% these should be cell arrays
if ~iscell(allowhost) && ischar(allowhost)
  allowhost = {allowhost};
end
if ~iscell(allowuser) && ischar(allowuser)
  allowuser = {allowuser};
end
if ~iscell(allowgroup) && ischar(allowgroup)
  allowgroup = {allowgroup};
end

% start the maintenance threads
ws = warning('off');
peer('tcpserver', 'start');
peer('announce',  'start');
peer('discover',  'start');
peer('expire',    'start');
warning(ws);

if ~isempty(hostname)
  peer('hostname', hostname);
end

if ~isempty(group)
  peer('group', group);
end

% impose access restrictions 
peer('allowhost',  allowhost);
peer('allowuser',  allowuser);
peer('allowgroup', allowgroup);

% the available resources will be announced and are used to drop requests that are too large
if ~isempty(memavail), peer('memavail', memavail); end
if ~isempty(cpuavail), peer('cpuavail', cpuavail); end
if ~isempty(timavail), peer('timavail', timavail); end
if ~isempty(threads),  maxNumCompThreads(threads); end

% switch to slave mode
peer('status', 1);

% remember the original working directory and the original path
orig_pwd = pwd;
orig_path = path;

% keep track of the time and number of jobs
stopwatch = tic;
prevtime  = toc(stopwatch);
jobnum    = 0;

while true

  if toc(stopwatch)>=maxtime
    fprintf('maxtime exceeded, stopping as slave\n');
    break;
  end

  if jobnum>=maxnum
    fprintf('maxnum exceeded, stopping as slave\n');
    break;
  end

  joblist = peer('joblist');

  if isempty(joblist)
    % wait a little bit and try again
    pause(sleep);

    % display the time every second
    currtime = toc(stopwatch);
    if (currtime-prevtime>=1)
      prevtime = currtime;
      disp(datestr(now));
    end

  else
    % increment the job counter
    jobnum = jobnum + 1;

    % reset the error and warning messages
    lasterr('');
    lastwarn('');

    % get the last job from the list, which will be the oldest
    joblist = joblist(end);

    fprintf('executing job %d from %s (jobid=%d)\n', jobnum, joblist.hostname, joblist.jobid);

    % get the input arguments and options
    [argin, options] = peer('get', joblist.jobid);

    try
      % there are many reasons why the execution may fail, hence the elaborate try-catch

      if ~iscell(argin)
        error('input argument should be a cell-array');
      end

      if ~ischar(argin{1})
        error('input argument #1 should be a string');
      end

      fname = argin{1};
      argin = argin(2:end);

      if ~iscell(options)
        error('input options should be a cell-array');
      end

      % try setting the same path directory
      option_path = keyval('path', options);
      if ~isempty(option_path)
        path(option_path, path);
      end

      % try changing to the same working directory
      option_pwd = keyval('pwd', options);
      if ~isempty(option_pwd)
        try
          cd(option_pwd);
        catch cd_error
          % don't throw an error, just give a warning (and hope for the best...)
          warning(cd_error.message);
        end
      end

      % there are potentially errors to catch from the which() function
      if isempty(which(fname))
        error('Not a valid M-file (%s).', fname);
      end

      % it can be difficult to determine the number of output arguments
      try
        numargout = nargout(fname);
      catch nargout_error
        if strcmp(nargout_error.identifier, 'MATLAB:narginout:doesNotApply')
          % e.g. in case of nargin('plus')
          numargout = 1;
        else
          rethrow(nargout_error);
        end
      end

      if numargout<0
        % the nargout function returns -1 in case of a variable number of output arguments
        numargout = 1;
      end

	  % start measuring the time and memory requirements
	  memprofile on
	  timused = toc(stopwatch);

      % evaluate the function and get the output arguments
	  argout  = cell(1, numargout);
	  [argout{:}] = feval(fname, argin{:});

	  % determine the time and memory requirements
      timused = toc(stopwatch) - timused;
      memstat = memprofile('info');
      memprofile off
      memprofile clear

      % determine the maximum amount of memory that was used during the function evaluation
      memused = max([memstat.mem]) - min([memstat.mem]);

      % Note that the estimated memory is inaccurate, because of
      % the dynamic memory management of Matlab and the garbage
      % collector. Especially on small jobs, the reported memory
      % use does not replect the size of the variables involved in
      % the computation. Matlab is able to squeeze these small jobs
      % in some left-over memory fragment that was not yet deallocated.
      % Larger memory jobs return more reliable measurements.

      fprintf('executing job %d took %f seconds and %d bytes\n', jobnum, timused, memused);

      % collect the output options
      options = {'timused', timused, 'memused', memused, 'lastwarn', lastwarn, 'lasterr', ''};

    catch feval_error
      argout  = {};
      % the output options will include the error
      options = {'lastwarn', lastwarn, 'lasterr', feval_error};
      % an error was detected while executing the job
      warning('an error was detected during job execution');
      % ensure that th ememory profiler is switched off
      memprofile off
      memprofile clear
    end

    try
      peer('put', joblist.hostid, argout, options, 'jobid', joblist.jobid);
    catch
      warning('failed to return job results to the master');
    end

    % remove the job from the tcpserver
    peer('clear', joblist.jobid);

    % revert to the original path
    if ~isempty(option_path)
      path(orig_path);
    end

    % revert to the original working directory
    if ~isempty(option_pwd)
      cd(orig_pwd);
    end

    % clear the function and any persistent variables in it
    clear(fname);

    % clear all temporary variables
    vars = whos;
    % easier would be to use the clearvars function, but that is only available in matlab 2008a and later
    vars = setdiff({vars.name}, {'stopwatch' 'prevtime' 'jobnum' 'maxnum' 'maxtime' 'sleep' 'orig_path' 'orig_pwd'});
    for indx=1:numel(vars)
      clear(vars{indx});
    end
    clear vars indx

    % clear any global variables
    clear global

  end % isempty(joblist)

end % while true

peer('status', 0);

